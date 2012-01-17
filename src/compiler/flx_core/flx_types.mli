open Flx_ast

type partial_order_result_t =
[
  | `Less
  | `Equal
  | `Greater
  | `Incomparable
]

type bid_t = int

val dummy_bid : bid_t

module BidSet : Flx_set.S with type elt = bid_t

(** Convert a list of bids into a bid set. *)
val bidset_of_list : bid_t list -> BidSet.t

type plain_ivs_list_t = (Flx_id.t * bid_t * typecode_t) list
type ivs_list_t = plain_ivs_list_t * vs_aux_t

type recstop = {
  constraint_overload_trail: bid_t list;
  idx_fixlist: bid_t list;
  type_alias_fixlist: (bid_t * int) list;
  as_fixlist: (string * int) list;
  expr_fixlist: (expr_t * int) list;
  depth: int;
  open_excludes: (ivs_list_t * qualified_name_t) list
}

(** {6 Pattern extractor}
 *
 * This type is used to extract components of a value, corresponding to a
 * match. *)
type dir_t =
  | DIR_open of ivs_list_t * qualified_name_t
  | DIR_inject_module of ivs_list_t * qualified_name_t
  | DIR_use of Flx_id.t * qualified_name_t

type sdir_t = Flx_srcref.t * dir_t

(** Used to represent all the different value types. *)
type value_kind_t = [ `Val | `Var | `Ref | `Lazy of expr_t ]

type dcl_t =
  (* data structures *)
  | DCL_axiom of         params_t * axiom_method_t
  | DCL_lemma of         params_t * axiom_method_t
  | DCL_reduce of        simple_parameter_t list * expr_t * expr_t
  | DCL_function of      params_t * typecode_t * property_t list * asm_t list
  | DCL_union of         (Flx_id.t * int option * vs_list_t * typecode_t) list
  | DCL_struct of        (Flx_id.t * typecode_t) list
  | DCL_cstruct of       (Flx_id.t * typecode_t) list * named_req_expr_t
  | DCL_typeclass of     asm_t list
  | DCL_match_check of   pattern_t * (string * bid_t)
  | DCL_match_handler of pattern_t * (string * bid_t) * asm_t list

  (* variables *)
  | DCL_value of         typecode_t * value_kind_t
  | DCL_type_alias of    typecode_t
  | DCL_inherit of       qualified_name_t
  | DCL_inherit_fun of   qualified_name_t

  (* module system *)
  | DCL_root of          asm_t list
  | DCL_module of        asm_t list
  | DCL_instance of      qualified_name_t * asm_t list

  (* binding structures [prolog] *)
  | DCL_newtype of       typecode_t
  | DCL_abs of           type_qual_t list * Flx_code_spec.t * named_req_expr_t
  | DCL_const of         property_t list * typecode_t * Flx_code_spec.t * named_req_expr_t
  | DCL_fun of           property_t list * typecode_t list * typecode_t * Flx_code_spec.t * named_req_expr_t * prec_t
  | DCL_callback of      property_t list * typecode_t list * typecode_t * named_req_expr_t
  | DCL_insert of        Flx_code_spec.t * ikind_t * named_req_expr_t

and access_t = [`Private | `Public ]

and sdcl_t = Flx_srcref.t * Flx_id.t * bid_t option * access_t * vs_list_t * dcl_t

and iface_t =
  | IFACE_export_fun of suffixed_name_t * string
  | IFACE_export_python_fun of suffixed_name_t * string
  | IFACE_export_type of typecode_t * string

and siface_t = Flx_srcref.t * iface_t

and asm_t =
  | Exe of sexe_t
  | Dcl of sdcl_t
  | Iface of siface_t
  | Dir of sdir_t

type bound_iface_t = Flx_srcref.t * iface_t * bid_t option

type bvs_t = (string * bid_t) list

type symbol_definition_t =
  | SYMDEF_newtype of typecode_t
  | SYMDEF_abs of type_qual_t list * Flx_code_spec.t * named_req_expr_t
  | SYMDEF_parameter of  param_kind_t * typecode_t
  | SYMDEF_typevar of typecode_t (* usually type TYPE *)
  | SYMDEF_axiom of params_t * axiom_method_t
  | SYMDEF_lemma of params_t * axiom_method_t
  | SYMDEF_reduce of parameter_t list * expr_t * expr_t
  | SYMDEF_function of params_t * typecode_t * property_t list * sexe_t list
  | SYMDEF_match_check of pattern_t * (string * bid_t)
  | SYMDEF_root of sexe_t list
  | SYMDEF_module of sexe_t list
  | SYMDEF_const_ctor of bid_t * typecode_t * int * ivs_list_t
  | SYMDEF_nonconst_ctor of bid_t * typecode_t * int * ivs_list_t * typecode_t
  | SYMDEF_const of property_t list * typecode_t * Flx_code_spec.t * named_req_expr_t
  | SYMDEF_var of typecode_t
  | SYMDEF_val of typecode_t
  | SYMDEF_ref of typecode_t
  | SYMDEF_lazy of typecode_t * expr_t
  | SYMDEF_fun of property_t list * typecode_t list * typecode_t * Flx_code_spec.t  * named_req_expr_t * prec_t
  | SYMDEF_callback of property_t list * typecode_t list * typecode_t * named_req_expr_t
  | SYMDEF_insert of Flx_code_spec.t * ikind_t * named_req_expr_t
  | SYMDEF_union of (Flx_id.t * int * vs_list_t * typecode_t) list
  | SYMDEF_struct of (Flx_id.t * typecode_t) list
  | SYMDEF_cstruct of (Flx_id.t * typecode_t) list * named_req_expr_t
  | SYMDEF_typeclass
  | SYMDEF_type_alias of typecode_t
  | SYMDEF_inherit of qualified_name_t
  | SYMDEF_inherit_fun of qualified_name_t
  | SYMDEF_instance of qualified_name_t

(* -------------------------------------------------------------------------- *)

(** Prints out a bid_t to a formatter. *)
val print_bid : Format.formatter -> bid_t -> unit

(** Prints a bvs_t to a formatter. *)
val print_bvs : Format.formatter -> bvs_t -> unit
