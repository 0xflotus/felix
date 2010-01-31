(** Inline exes *)

open Flx_ast
open Flx_types
open Flx_set
open Flx_mtypes2
open Flx_call

type submode_t = [`Eager | `Lazy]

val gen_body :
  sym_state_t ->
  usage_table_t * Flx_child.t * Flx_bsym_table.t ->
  string ->                         (* name *)
  (bid_t, btypecode_t) Hashtbl.t -> (* varmap *)
  Flx_bparameter.t list ->          (* parameters *)
  (string, string) Hashtbl.t ->     (* relabel *)
  (bid_t, bid_t) Hashtbl.t ->       (* revariable *)
  Flx_bexe.t list ->                (* the exes *)
  Flx_bexpr.t ->                    (* argument *)
  Flx_srcref.t ->                   (* srcref *)
  bid_t ->                          (* caller *)
  bid_t ->                          (* callee *)
  bvs_t ->                          (* caller vs *)
  int ->                            (* callee vs len *)
  submode_t ->                      (* default arg passing mode *)
  property_t list ->                (* properties *)
  Flx_bexe.t list

val recal_exes_usage:
  usage_table_t ->
  Flx_srcref.t ->
  bid_t ->
  Flx_bparameter.t list ->
  Flx_bexe.t list ->
  unit
