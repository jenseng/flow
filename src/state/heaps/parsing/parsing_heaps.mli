(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

type locs_tbl = Loc.t Type_sig_collections.Locs.t

type type_sig = Type_sig_collections.Locs.index Packed_type_sig.Module.t

type file_addr = SharedMem.NewAPI.dyn_file SharedMem.addr

type checked_file_addr = SharedMem.NewAPI.checked_file SharedMem.addr

type info = {
  module_name: string option;
  checked: bool;  (** in flow? *)
  parsed: bool;  (** if false, it's a tracking record only *)
}

val is_checked_file : file_addr -> bool

module type READER = sig
  type reader

  val has_ast : reader:reader -> File_key.t -> bool

  val get_ast : reader:reader -> File_key.t -> (Loc.t, Loc.t) Flow_ast.Program.t option

  val get_docblock : reader:reader -> File_key.t -> Docblock.t option

  val get_exports : reader:reader -> File_key.t -> Exports.t option

  val get_tolerable_file_sig : reader:reader -> File_key.t -> File_sig.With_Loc.tolerable_t option

  val get_file_sig : reader:reader -> File_key.t -> File_sig.With_Loc.t option

  val get_type_sig : reader:reader -> File_key.t -> type_sig option

  val get_file_hash : reader:reader -> File_key.t -> Xx.hash option

  val get_ast_unsafe : reader:reader -> File_key.t -> (Loc.t, Loc.t) Flow_ast.Program.t

  val get_aloc_table_unsafe : reader:reader -> File_key.t -> ALoc.table

  val get_docblock_unsafe : reader:reader -> File_key.t -> Docblock.t

  val get_exports_unsafe : reader:reader -> File_key.t -> Exports.t

  val get_tolerable_file_sig_unsafe : reader:reader -> File_key.t -> File_sig.With_Loc.tolerable_t

  val get_file_sig_unsafe : reader:reader -> File_key.t -> File_sig.With_Loc.t

  val get_file_addr_unsafe : reader:reader -> File_key.t -> file_addr

  val get_checked_file_addr_unsafe : reader:reader -> File_key.t -> checked_file_addr

  val get_type_sig_unsafe : reader:reader -> File_key.t -> type_sig

  val get_file_hash_unsafe : reader:reader -> File_key.t -> Xx.hash

  val loc_of_aloc : reader:reader -> ALoc.t -> Loc.t

  (** given a filename, returns module info *)
  val get_info_unsafe : reader:reader -> (File_key.t -> info) Expensive.t

  val get_info : reader:reader -> (File_key.t -> info option) Expensive.t
end

module Mutator_reader : sig
  include READER with type reader = Mutator_state_reader.t

  val get_old_file_hash : reader:Mutator_state_reader.t -> File_key.t -> Xx.hash option

  val get_old_exports : reader:Mutator_state_reader.t -> File_key.t -> Exports.t option

  val get_old_info : reader:reader -> (File_key.t -> info option) Expensive.t
end

module Reader : READER with type reader = State_reader.t

module Reader_dispatcher : READER with type reader = Abstract_state_reader.t

(* For use by a worker process *)
type worker_mutator = {
  add_parsed:
    File_key.t ->
    exports:Exports.t ->
    Xx.hash ->
    string option ->
    Docblock.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t ->
    File_sig.With_Loc.tolerable_t ->
    locs_tbl ->
    type_sig ->
    unit;
  add_unparsed: File_key.t -> Xx.hash -> string option -> unit;
}

module Parse_mutator : sig
  val create : unit -> worker_mutator
end

module Reparse_mutator : sig
  type master_mutator (* Used by the master process *)

  val create : Transaction.t -> Utils_js.FilenameSet.t -> master_mutator * worker_mutator

  val revive_files : master_mutator -> Utils_js.FilenameSet.t -> unit
end

module From_saved_state : sig
  val add_parsed : File_key.t -> Xx.hash -> string option -> Exports.t -> unit

  val add_unparsed : File_key.t -> Xx.hash -> string option -> unit
end
