(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Reason
open Type
open Constraint

(* Helper module for full type resolution as needed to check union and
   intersection types.

   Given a type, we walk it to collect the parts of it we wish to resolve. Once
   these parts are resolved, they must themselves be walked to collect further
   parts to resolve, and so on. In other words, type resolution jobs are created
   and processed in rounds, moving closer and closer to full resolution of the
   original type. Needless to say, these jobs can be recursive, and so must be
   managed carefully for termination and performance. The job management itself
   is done in Graph_explorer. (The jobs are naturally modeled as a graph with
   dynamically created nodes and edges.)

   Here, we define the function that creates a single round of such jobs.
*)

(* A datatype describing type resolution jobs.

   We unfold types as we go, looking for parts that cannot be unfolded
   immediately (thus needing resolution to proceed).

   The handling of these parts involve calls to `flow` and `unify`, and is
   thus decoupled from the walker itself for clarity. Here, we just create
   different jobs for different parts encountered. These jobs are further
   processed by bindings_of_jobs.

   Briefly, jobs are created for the following cases. (1) Annotation sources
   need to be resolved. (2) So do heads of type applications. (3) Resolved
   tvars are recursively unfolded, but we need to remember which resolved
   tvars have been unfolded to prevent infinite unfolding. (4) Unresolved
   tvars are handled differently based on context: when they are expected
   (e.g., when they are part of inferred types), they are logged; when they
   are unexpected (e.g., when they are part of annotations), they are
   converted to `any`. For more details see bindings_of_jobs.
*)
type t =
  | Binding of Type.tvar
  | OpenResolved
  | OpenUnresolved of int option * reason * Type.ident

(* log_unresolved is a mode that determines whether to log unresolved tvars:
   it is None when resolving annotations, and Some speculation_id when
   resolving inferred types. *)
let rec collect_of_types ?log_unresolved cx = List.fold_left (collect_of_type ?log_unresolved cx)

and collect_of_type ?log_unresolved cx acc = function
  | OpenT (r, id) ->
    let (id, constraints) = Context.find_constraints cx id in
    if IMap.mem id acc then
      acc
    else (
      match constraints with
      | FullyResolved _ ->
        (* Everything reachable from this type is certainly resolved, so we can
           avoid walking the type entirely. *)
        acc
      | Resolved t ->
        let acc = IMap.add id OpenResolved acc in
        collect_of_type ?log_unresolved cx acc t
      | Unresolved _ ->
        (* It is important to consider reads of constant property names as fully
           resolvable, especially since constant property names are often used to
           store literals that serve as tags for disjoint unions. Unfortunately,
           today we cannot distinguish such reads from others, so we rely on a
           common style convention to recognize constant property names. For now
           this hack pays for itself: we do not ask such reads to be annotated
           with the corresponding literal types to decide membership in those
           disjoint unions. *)
        if is_constant_reason r then
          IMap.add id (Binding (r, id)) acc
        (* Instantiable reasons indicate unresolved tvars that are created
           "fresh" for the sole purpose of binding to other types, e.g. as
           instantiations of type parameters. Constraining them during speculative
           matching typically do not cause side effects across branches, and help
           make progress. *)
        else if is_instantiable_reason r then
          acc
        else
          IMap.add id (OpenUnresolved (log_unresolved, r, id)) acc
    )
  | AnnotT (_, t, _) -> collect_of_binding ?log_unresolved cx acc t
  | ThisTypeAppT (_, t, _, targs_opt) ->
    let acc = collect_of_binding ?log_unresolved cx acc t in
    let acc =
      match targs_opt with
      | None -> acc
      | Some targs -> collect_of_types ?log_unresolved cx acc targs
    in
    acc
  | TypeAppT { reason = _; use_op = _; type_; targs; from_value = _; use_desc = _ } ->
    let acc = collect_of_binding ?log_unresolved cx acc type_ in
    let acc = collect_of_types ?log_unresolved cx acc targs in
    acc
  | EvalT (t, TypeDestructorT (_, _, d), _) ->
    let acc = collect_of_type ?log_unresolved cx acc t in
    collect_of_destructor ?log_unresolved cx acc d
  (* Some common kinds of types are quite overloaded: sometimes they
     correspond to types written by the user, but sometimes they also model
     internal types, and as such carry other bits of information. For now, we
     walk only some parts of these types. These parts are chosen such that
     they directly correspond to parts of the surface syntax of types. It is
     less clear what it means to resolve other "internal" parts of these
     types. In theory, ignoring them *might* lead to bugs, but we've not seen
     examples of such bugs yet. Leaving further investigation of this point as
     future work. *)
  | DefT (_, ObjT { props_tmap; flags; call_t; _ }) ->
    let props_tmap = Context.find_props cx props_tmap in
    let acc = NameUtils.Map.fold (collect_of_property ?log_unresolved cx) props_tmap acc in
    let ts =
      match flags.obj_kind with
      | Indexed { key; value; _ } -> [key; value]
      | _ -> []
    in
    let ts =
      match call_t with
      | None -> ts
      | Some id -> Context.find_call cx id :: ts
    in
    collect_of_types ?log_unresolved cx acc ts
  | DefT (_, FunT (_, { params; return_t; predicate; _ })) ->
    let ts = List.fold_left (fun acc (_, t) -> t :: acc) [return_t] params in
    let ts =
      match predicate with
      | Some (TypeGuardBased { type_guard = t; _ }) -> t :: ts
      | _ -> ts
    in
    collect_of_types ?log_unresolved cx acc ts
  | DefT (_, ArrT (ArrayAT { elem_t; tuple_view = None; react_dro = _ })) ->
    collect_of_type ?log_unresolved cx acc elem_t
  | DefT
      ( _,
        ArrT
          (ArrayAT { elem_t; tuple_view = Some (TupleView { elements; arity = _ }); react_dro = _ })
      )
  | DefT (_, ArrT (TupleAT { elem_t; elements; arity = _; react_dro = _ })) ->
    collect_of_types ?log_unresolved cx acc (elem_t :: TypeUtil.tuple_ts_of_elements elements)
  | DefT (_, ArrT (ROArrayAT (elemt, _))) -> collect_of_type ?log_unresolved cx acc elemt
  | DefT
      ( _,
        InstanceT
          {
            static;
            super;
            implements = _;
            inst = { class_id; type_args; own_props; proto_props; inst_call_t; _ };
          }
      ) ->
    let ts =
      if class_id = ALoc.id_none then
        []
      else
        [super; static]
    in
    let ts = List.fold_left (fun ts (_, _, t, _) -> t :: ts) ts type_args in
    let props_tmap =
      NameUtils.Map.union (Context.find_props cx own_props) (Context.find_props cx proto_props)
    in
    let ts =
      NameUtils.Map.fold (fun _ p ts -> Property.fold_t (fun ts t -> t :: ts) ts p) props_tmap ts
    in
    let ts =
      match inst_call_t with
      | None -> ts
      | Some id -> Context.find_call cx id :: ts
    in
    collect_of_types ?log_unresolved cx acc ts
  | DefT (_, PolyT { t_out = t; _ }) -> collect_of_type ?log_unresolved cx acc t
  | NamespaceT { values_type; types_tmap } ->
    let acc = collect_of_type ?log_unresolved cx acc values_type in
    let acc =
      NameUtils.Map.fold
        (collect_of_property ?log_unresolved cx)
        (Context.find_props cx types_tmap)
        acc
    in
    acc
  (* TODO: The following kinds of types are not walked out of laziness. It's
     not immediately clear what we'd gain (or lose) by walking them. *)
  | InternalT (ChoiceKitT (_, _))
  | ModuleT
      {
        module_reason = _;
        module_export_types = _;
        module_is_strict = _;
        module_available_platforms = _;
      }
  | InternalT (ExtendsT _)
  | InternalT (EnforceUnionOptimized _) ->
    acc
  (* The following cases exactly follow Type_visitor (i.e., they do the
     standard walk). TODO: Rewriting this walker as a subclass of Type_visitor
     would be quite nice (as long as we confirm that the resulting
     virtualization of calls to this function doesn't lead to perf
     degradation: this function is expected to be quite hot). *)
  | OptionalT { reason = _; type_ = t; use_desc = _ }
  | MaybeT (_, t) ->
    collect_of_type ?log_unresolved cx acc t
  | UnionT (_, rep) ->
    let ts = UnionRep.members rep in
    collect_of_types ?log_unresolved cx acc ts
  | IntersectionT (_, rep) ->
    let ts = InterRep.members rep in
    collect_of_types ?log_unresolved cx acc ts
  | DefT (_, ReactAbstractComponentT { config; instance; renders; component_kind = _ }) ->
    collect_of_types ?log_unresolved cx acc [config; instance; renders]
  | DefT (_, RendersT (StructuralRenders { renders_variant = _; renders_structural_type = t })) ->
    collect_of_type ?log_unresolved cx acc t
  | DefT (_, RendersT (NominalRenders { renders_id = _; renders_name = _; renders_super })) ->
    collect_of_type ?log_unresolved cx acc renders_super
  | OpaqueT (_, { underlying_t; super_t; _ }) ->
    let acc = Base.Option.fold underlying_t ~init:acc ~f:(collect_of_type ?log_unresolved cx) in
    let acc = Base.Option.fold super_t ~init:acc ~f:(collect_of_type ?log_unresolved cx) in
    acc
  | ExactT (_, t)
  | DefT (_, TypeT (_, t))
  | DefT (_, ClassT t) ->
    collect_of_type ?log_unresolved cx acc t
  | ThisInstanceT (r, t, _, _) -> collect_of_type ?log_unresolved cx acc (DefT (r, InstanceT t))
  | KeysT (_, t) -> collect_of_type ?log_unresolved cx acc t
  | MatchingPropT (_, _, t) -> collect_of_type ?log_unresolved cx acc t
  | GenericT { bound; _ } -> collect_of_type ?log_unresolved cx acc bound
  | DefT (_, EnumValueT enum_info) -> collect_of_enum_info ?log_unresolved cx acc enum_info
  | DefT (_, EnumObjectT { enum_value_t; enum_info }) ->
    let acc = collect_of_enum_info ?log_unresolved cx acc enum_info in
    collect_of_type ?log_unresolved cx acc enum_value_t
  | DefT (_, NumT _)
  | DefT (_, StrT _)
  | DefT (_, BoolT _)
  | DefT (_, BigIntT _)
  | DefT (_, SymbolT)
  | DefT (_, VoidT)
  | DefT (_, NullT)
  | DefT (_, EmptyT)
  | DefT (_, MixedT _)
  | DefT (_, NumericStrKeyT _)
  | DefT (_, SingletonBoolT _)
  | DefT (_, SingletonNumT _)
  | DefT (_, SingletonStrT _)
  | DefT (_, SingletonBigIntT _)
  | AnyT _ ->
    acc
  | FunProtoBindT _
  | FunProtoCallT _
  | FunProtoApplyT _
  | FunProtoT _
  | NullProtoT _
  | ObjProtoT _
  | CustomFunT (_, _) ->
    acc

and collect_of_destructor ?log_unresolved cx acc = function
  | ReactCheckComponentConfig map ->
    NameUtils.Map.fold (collect_of_property ?log_unresolved cx) map acc
  | NonMaybeType -> acc
  | ReactDRO _ -> acc
  | MakeHooklike -> acc
  | ReactCheckComponentRef -> acc
  | PropertyType _ -> acc
  | EnumType -> acc
  | ElementType { index_type; _ } -> collect_of_type ?log_unresolved cx acc index_type
  | OptionalIndexedAccessResultType _ -> acc
  | OptionalIndexedAccessNonMaybeType { index = OptionalIndexedAccessTypeIndex index_type } ->
    collect_of_type ?log_unresolved cx acc index_type
  | OptionalIndexedAccessNonMaybeType { index = OptionalIndexedAccessStrLitIndex _ } -> acc
  | ReadOnlyType -> acc
  | RequiredType
  | PartialType ->
    acc
  | SpreadType (_, ts, head_slice) ->
    let acc = collect_of_object_kit_spread_operands ?log_unresolved cx acc ts in
    begin
      match head_slice with
      | None -> acc
      | Some head_slice ->
        collect_of_object_kit_spread_operand_slice ?log_unresolved cx acc head_slice
    end
  | SpreadTupleType { resolved; unresolved; reason_tuple = _; reason_spread = _ } ->
    let acc =
      List.fold_left
        (fun acc -> function
          | UnresolvedArg (TupleElement { t; _ }, _)
          | UnresolvedSpreadArg t ->
            collect_of_type ?log_unresolved cx acc t)
        acc
        unresolved
    in
    List.fold_left
      (fun acc -> function
        | ResolvedArg (TupleElement { t; _ }, _) -> collect_of_type ?log_unresolved cx acc t
        | ResolvedSpreadArg (_, arr, _) ->
          (match arr with
          | ArrayAT { elem_t; tuple_view = None; react_dro = _ } ->
            collect_of_type ?log_unresolved cx acc elem_t
          | ArrayAT { elem_t; tuple_view = Some (TupleView { elements; arity = _ }); react_dro = _ }
          | TupleAT { elem_t; elements; arity = _; react_dro = _ } ->
            collect_of_types
              ?log_unresolved
              cx
              acc
              (elem_t :: TypeUtil.tuple_ts_of_elements elements)
          | ROArrayAT (elemt, _) -> collect_of_type ?log_unresolved cx acc elemt)
        | ResolvedAnySpreadArg _ -> acc)
      acc
      resolved
  | RestType (_, t) -> collect_of_type ?log_unresolved cx acc t
  | ValuesType -> acc
  | CallType { from_maptype = _; args = ts } -> collect_of_types ?log_unresolved cx acc ts
  | ConditionalType { distributive_tparam_name = _; infer_tparams; extends_t; true_t; false_t } ->
    let acc =
      collect_of_types
        ?log_unresolved
        cx
        acc
        (Base.List.map infer_tparams ~f:(fun tparam -> tparam.Type.bound))
    in
    collect_of_types ?log_unresolved cx acc [extends_t; true_t; false_t]
  | TypeMap tmap -> collect_of_type_map ?log_unresolved cx acc tmap
  | ReactConfigType default_props -> collect_of_type ?log_unresolved cx acc default_props
  | MappedType
      { property_type; mapped_type_flags = _; homomorphic = _; distributive_tparam_name = _ } ->
    collect_of_type ?log_unresolved cx acc property_type
  | ReactPromoteRendersRepresentation
      {
        should_distribute = _;
        promote_structural_components = _;
        renders_variant = _;
        resolved_elem;
      } ->
    (match resolved_elem with
    | Some t -> collect_of_type ?log_unresolved cx acc t
    | None -> acc)
  | ReactElementPropsType
  | ReactElementConfigType
  | ReactElementRefType ->
    acc

and collect_of_property ?log_unresolved cx name property acc =
  if is_internal_name name then
    acc
  else
    Property.fold_t (fun acc -> collect_of_type ?log_unresolved cx acc) acc property

and collect_of_object_kit_spread_operand_slice
    ?log_unresolved
    cx
    acc
    { Object.Spread.reason = _; prop_map; dict; generics = _; reachable_targs = _ } =
  let acc = NameUtils.Map.fold (collect_of_property ?log_unresolved cx) prop_map acc in
  let ts =
    match dict with
    | Some { key; value; dict_polarity = _; dict_name = _ } -> [key; value]
    | None -> []
  in
  collect_of_types ?log_unresolved cx acc ts

and collect_of_object_kit_spread_operand ?log_unresolved cx acc = function
  | Object.Spread.Slice operand_slice ->
    collect_of_object_kit_spread_operand_slice ?log_unresolved cx acc operand_slice
  | Object.Spread.Type t -> collect_of_type ?log_unresolved cx acc t

and collect_of_object_kit_spread_operands ?log_unresolved cx acc operands =
  List.fold_left
    (fun acc op -> collect_of_object_kit_spread_operand ?log_unresolved cx acc op)
    acc
    operands

and collect_of_type_map ?log_unresolved cx acc = function
  | TupleMap t
  | ObjectMap t
  | ObjectMapi t
  | ObjectMapConst t ->
    collect_of_type ?log_unresolved cx acc t
  | ObjectKeyMirror -> acc

(* In some positions, like annots, we trust that tvars are 0->1. *)
and collect_of_binding ?log_unresolved cx acc = function
  | OpenT ((_, id) as tvar) ->
    let (id, constraints) = Context.find_constraints cx id in
    if IMap.mem id acc then
      acc
    else (
      match constraints with
      | FullyResolved _ ->
        (* Everything reachable from this type is certainly resolved, so we can
           avoid walking the type entirely. *)
        acc
      | Resolved t ->
        let acc = IMap.add id OpenResolved acc in
        collect_of_type ?log_unresolved cx acc t
      | Unresolved _ -> IMap.add id (Binding tvar) acc
    )
  | t -> collect_of_type ?log_unresolved cx acc t

(* TODO: Support for use types is currently sketchy. Full resolution of use
   types are only needed for choice-making on intersections. We care about
   calls in particular because one of the biggest uses of intersections is
   function overloading. More uses will be added over time. *)
and collect_of_use ?log_unresolved cx acc = function
  | UseT (_, t) -> collect_of_type ?log_unresolved cx acc t
  | CallT { call_action = Funcalltype fct; reason = _; use_op = _; return_hint = _ } ->
    let arg_types =
      Base.List.map
        ~f:(function
          | Arg t
          | SpreadArg t ->
            t)
        fct.call_args_tlist
    in
    collect_of_types ?log_unresolved cx acc (arg_types @ [OpenT fct.call_tout])
  | GetPropT { tout; _ } -> collect_of_type ?log_unresolved cx acc (OpenT tout)
  | _ -> acc

and collect_of_enum_info ?log_unresolved cx acc = function
  | AbstractEnum { representation_t }
  | ConcreteEnum { representation_t; _ } ->
    collect_of_type ?log_unresolved cx acc representation_t
