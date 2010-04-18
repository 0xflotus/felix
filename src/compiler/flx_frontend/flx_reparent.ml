open Flx_util
open Flx_ast
open Flx_types
open Flx_btype
open Flx_bexpr
open Flx_bexe
open Flx_bparameter
open Flx_bbdcl
open Flx_print
open Flx_set
open Flx_mtypes2
open Flx_typing
open List
open Flx_unify
open Flx_maps
open Flx_exceptions
open Flx_use

let mk_remap counter d =
  let m = Hashtbl.create 97 in
  BidSet.iter (fun i -> Hashtbl.add m i (fresh_bid counter)) d;
  m

(* replace callee type variables with callers *)
let vsplice caller_vars callee_vs_len ts =
  if not (callee_vs_len <= length ts)
  then failwith
  (
    "Callee_vs_len = " ^
    si callee_vs_len ^
    ", len vs/ts= " ^
    si (length ts) ^
    ", length caller_vars = " ^
    si (length caller_vars)
  )
  ;
  let rec aux lst n =  (* elide first n elements *)
    if n = 0 then lst
    else aux (tl lst) (n-1)
  in
  caller_vars @ aux ts callee_vs_len


let remap_expr
  syms
  bsym_table
  varmap        (** varmap is the type variable remapper *)
  revariable    (** revariable remaps indices. *)
  caller_vars
  callee_vs_len
  e
=
  (*
  print_endline ("Remapping expression " ^ sbe sym_table bsym_table e);
  *)
  let ftc i ts = Flx_typeclass.maybe_fixup_typeclass_instance syms bsym_table i ts in
  let revar i = try Hashtbl.find revariable i with Not_found -> i in
  let tmap t = match t with
  | BTYP_inst (i,ts) -> btyp_inst (revar i,ts)
  | x -> x
  in
  let auxt t =
    let t' = varmap_subst varmap t in
    let rec f_btype t = tmap (Flx_btype.map ~f_btype t) in
    let t' = f_btype t' in
    (* print_endline ("Remap type " ^ sbt sym_table t ^ " to " ^ sbt sym_table * t'); *)
    t'
  in
  let fixup i ts =
    let ts = map auxt ts in
    try
      let j= Hashtbl.find revariable i in
      j, vsplice caller_vars callee_vs_len ts
    with Not_found -> i,ts
  in
  let rec aux e =
    match Flx_bexpr.map ~f_btype:auxt ~f_bexpr:aux e with
    | BEXPR_name (i,ts),t ->
        let i,ts = fixup i ts in
        bexpr_name (auxt t) (i,ts)

    | BEXPR_ref (i,ts) as x,t ->
        let i,ts = fixup i ts in
        bexpr_ref (auxt t) (i,ts)

    | BEXPR_closure (i,ts),t ->
        let i,ts = fixup i ts in
        bexpr_closure (auxt t) (i,ts)

    | BEXPR_apply_direct (i,ts,e),t ->
        let i,ts = fixup i ts in

        (* attempt to fixup typeclass virtual *)
        let i,ts = ftc i ts in
        bexpr_apply_direct (auxt t) (i,ts,aux e)

    | BEXPR_apply_stack (i,ts,e),t ->
        let i,ts = fixup i ts in
        bexpr_apply_stack (auxt t) (i,ts,aux e)

    | BEXPR_apply_prim (i,ts,e),t ->
        let i,ts = fixup i ts in
        bexpr_apply_prim (auxt t) (i,ts,aux e)

    | x,t -> x, auxt t
  in
  let a = aux e in
  (*
  print_endline ("replace " ^ sbe sym_table e ^ "-->" ^ sbe sym_table a);
  *)
  a

let remap_exe
  syms
  bsym_table
  relabel
  varmap        (** varmap is the type variable remapper *)
  revariable    (** revariable remaps indices. *)
  caller_vars
  callee_vs_len
  exe
=
  (*
  print_endline ("remap_exe " ^ string_of_bexe sym_table bsym_table 0 exe);
  *)
  let ge e = remap_expr syms bsym_table varmap revariable caller_vars callee_vs_len e in
  let revar i = try Hashtbl.find revariable i with Not_found -> i in
  let relab s = try Hashtbl.find relabel s with Not_found -> s in
  let ftc i ts = Flx_typeclass.maybe_fixup_typeclass_instance syms bsym_table i ts in

  let tmap t = match t with
  | BTYP_inst (i,ts) -> btyp_inst (revar i,ts)
  | x -> x
  in
  let auxt t =
    let t' = varmap_subst varmap t in
    let rec f_btype t = tmap (Flx_btype.map ~f_btype t) in
    let t' = f_btype t' in
    (* print_endline ("Remap type " ^ sbt sym_table t ^ " to " ^ sbt sym_table * t'); *)
    t'
  in
  let exe =
  match exe with
  | BEXE_axiom_check _ -> assert false
  | BEXE_call_prim (sr,i,ts,e2) -> assert false
    (*
    let fixup i ts =
      let ts = map auxt ts in
      try
        let j= Hashtbl.find revariable i in
        j, vsplice caller_vars callee_vs_len ts
      with Not_found -> i,ts
    in
    let i,ts = fixup i ts in
    BEXE_call_prim (sr,i,ts, ge e2)
    *)

  | BEXE_call_direct (sr,i,ts,e2) -> assert false
    (*
    let fixup i ts =
      let ts = map auxt ts in
      try
        let j= Hashtbl.find revariable i in
        j, vsplice caller_vars callee_vs_len ts
      with Not_found -> i,ts
    in
    let i,ts = fixup i ts in

    (* attempt to instantiate typeclass virtual *)
    let i,ts = ftc i ts in
    BEXE_call_direct (sr,i,ts, ge e2)
    *)

  | BEXE_call_stack (sr,i,ts,e2) -> assert false
    (*
    let fixup i ts =
      let ts = map auxt ts in
      try
        let j= Hashtbl.find revariable i in
        j, vsplice caller_vars callee_vs_len ts
      with Not_found -> i,ts
    in
    let i,ts = fixup i ts in
    BEXE_call_stack (sr,i,ts, ge e2)
    *)
  | BEXE_label (sr,lab) -> bexe_label (sr,relab lab)
  | BEXE_goto (sr,lab) -> bexe_goto (sr,relab lab)
  | BEXE_ifgoto (sr,e,lab) -> bexe_ifgoto (sr,ge e,relab lab)

  | x -> Flx_bexe.map ~f_bid:revar ~f_bexpr:ge x
  in
  (*
  print_endline ("remapped_exe " ^ string_of_bexe sym_table bsym_table 0 exe);
  *)
  exe


let remap_exes syms bsym_table relabel varmap revariable caller_vars callee_vs_len exes =
  map (remap_exe syms bsym_table relabel varmap revariable caller_vars callee_vs_len) exes

let remap_reqs syms bsym_table varmap revariable caller_vars callee_vs_len reqs : breqs_t =
  let revar i = try Hashtbl.find revariable i with Not_found -> i in
  let tmap t = match t with
  | BTYP_inst (i,ts) -> btyp_inst (revar i,ts)
  | x -> x
  in
  let auxt t =
    let t' = varmap_subst varmap t in
    let rec f_btype t = tmap (Flx_btype.map ~f_btype t) in
    let t' = f_btype t' in
    (* print_endline ("Remap type " ^ sbt sym_table t ^ " to " ^ sbt sym_table * t'); *)
    t'
  in
  let fixup (i, ts) =
    let ts = map auxt ts in
    try
      let j= Hashtbl.find revariable i in
      j, vsplice caller_vars callee_vs_len ts
    with Not_found -> i,ts
  in
  map fixup reqs


(* this routine makes a (type) specialised version of a symbol:
   a function, procedure, variable, or whatever.

   relabel: maps old labels onto fresh labels
   revariable: maps old variables and functions to fresh ones
   varmap: maps type variables to types (type specialisation)
   index: this routine
   parent: the new parent

   this routine doesn't specialise any children,
   just any reference to them: the kids need
   to be specialised by reparent_children.
*)

let allow_rescan flag props =
  match flag with
  | false -> props
  | true -> filter (function | `Inlining_complete | `Inlining_started -> false | _ -> true ) props

let reparent1
  (syms:sym_state_t)
  uses
  bsym_table
  relabel
  varmap
  revariable
  caller_vs
  callee_vs_len
  index         (** Routine index. *)
  parent        (** The parent symbol. *)
  k             (** New index, perhaps the caller. *)
  rescan_flag   (** Allow rescan of cloned stuff? *)
=
  let splice vs = (* replace callee type variables with callers *)
    vsplice caller_vs callee_vs_len vs
  in
  let sop = function
    | None -> "NONE?"
    | Some i -> string_of_bid i
  in
  let caller_vars = map
    (fun (s,i) -> btyp_type_var (i, btyp_type 0))
    caller_vs
  in

  let revar i = try Hashtbl.find revariable i with Not_found -> i in
  let tmap t = match t with
  | BTYP_inst (i,ts) -> btyp_inst (revar i,ts)
  | x -> x
  in
  let auxt t =
    let t' = varmap_subst varmap t in
    let rec f_btype t = tmap (Flx_btype.map ~f_btype t) in
    let t' = f_btype t' in
    (* print_endline ("Remap type " ^ sbt sym_table t ^ " to " ^ sbt sym_table * t'); *)
    t'
  in
  let remap_ps ps = map (fun {pid=id; pindex=i; ptyp=t; pkind=k} ->
    {pid=id; pindex=revar i; ptyp=auxt t; pkind=k})
     ps
   in

  let rexes xs = remap_exes syms bsym_table relabel varmap revariable caller_vars callee_vs_len xs in
  let rexpr e = remap_expr syms bsym_table varmap revariable caller_vars callee_vs_len e in
  let rreqs rqs = remap_reqs syms bsym_table varmap revariable caller_vars callee_vs_len rqs in
  let bsym = Flx_bsym_table.find bsym_table index in
  let bsym_parent = Flx_bsym_table.find_parent bsym_table index in
  if syms.compiler_options.print_flag then
  print_endline
  (
    "COPYING " ^ Flx_bsym.id bsym ^ " index " ^ string_of_bid index ^
    " with old parent " ^ sop bsym_parent ^ " to index " ^
    string_of_bid k ^ " with new parent " ^ sop parent
  );
  let update_bsym bbdcl =
    Flx_bsym_table.remove bsym_table k;
    Flx_bsym_table.add bsym_table parent k (Flx_bsym.replace_bbdcl bsym bbdcl)
  in

  match Flx_bsym.bbdcl bsym with
  | BBDCL_function (props, vs, (ps,traint), ret, exes) ->
    let props = allow_rescan rescan_flag props in
    let props = filter (fun p -> p <> `Virtual) props in
    let ps = remap_ps ps in
    let exes = rexes exes in
    let ret = auxt ret in
    update_bsym (bbdcl_function (props,splice vs,(ps,traint),ret,exes));
    let calls = try Hashtbl.find uses index with Not_found -> [] in
    let calls = map (fun (j,sr) -> revar j,sr) calls in
    Hashtbl.add uses k calls

  | BBDCL_val (vs,t,kind) ->
    update_bsym (bbdcl_val (splice vs,auxt t,kind))

  | BBDCL_abs (vs,quals,ct,breqs) ->
    let vs = splice vs in
    let breqs = rreqs breqs in
    update_bsym (bbdcl_abs (vs,quals,ct,breqs));
    let calls = try Hashtbl.find uses index with Not_found -> [] in
    let calls = map (fun (j,sr) -> revar j,sr) calls in
    Hashtbl.add uses k calls

  | BBDCL_const (props,vs,t,ct,breqs) ->
    let props = filter (fun p -> p <> `Virtual) props in
    let vs = splice vs in
    let breqs = rreqs breqs in
    let t = auxt t in
    update_bsym (bbdcl_const (props,vs,t,ct,breqs));
    let calls = try Hashtbl.find uses index with Not_found -> [] in
    let calls = map (fun (j,sr) -> revar j,sr) calls in
    Hashtbl.add uses k calls

  | BBDCL_external_fun (props,vs,params,ret,ct,breqs,prec) ->
    let props = filter (fun p -> p <> `Virtual) props in
    let params = map auxt params in
    let vs = splice vs in
    let ret = auxt ret in
    let breqs = rreqs breqs in
    update_bsym (bbdcl_external_fun (props,vs,params,ret,ct,breqs,prec));
    let calls = try Hashtbl.find uses index with Not_found -> [] in
    let calls = map (fun (j,sr) -> revar j,sr) calls in
    Hashtbl.add uses k calls

  | BBDCL_insert (vs,ct,ik,breqs) ->
    let breqs = rreqs breqs in
    let vs = splice vs in
    update_bsym (bbdcl_insert (vs,ct,ik,breqs));
    let calls = try Hashtbl.find uses index with Not_found -> [] in
    let calls = map (fun (j,sr) -> revar j,sr) calls in
    Hashtbl.add uses k calls

  (*
  |  _ ->
    Flx_bsym_table.add bsym_table k (id,parent,sr,entry)
  *)

  | _ ->
    syserr (Flx_bsym.sr bsym) ("[reparent1] Unexpected: bbdcl " ^
      string_of_bbdcl bsym_table (Flx_bsym.bbdcl bsym) index)

(* make a copy all the descendants of i, changing any
  parent which is i to the given new parent
*)

(* this routine reparents all the children of a given
   routine, but it doesn't reparent the routine itself
*)

let reparent_children syms uses bsym_table
  caller_vs callee_vs_len index (parent:bid_t option) relabel varmap rescan_flag extras
=
  (*
  let pp p = match p with None -> "NONE" | Some i -> string_of_bid i in
  print_endline
  (
    "Renesting children of callee " ^ si index ^
    " to caller " ^ pp parent ^
     "\n  -- Caller vs len = " ^ si (length caller_vs) ^
     "\n  -- Callee vs len = " ^ si (callee_vs_len)
  );
  *)

  let closure = Flx_bsym_table.find_descendants bsym_table index in
  assert (not (BidSet.mem index closure));
  let revariable = fold_left (fun acc i -> BidSet.add i acc) closure extras in
  (*
  let cl = ref [] in BidSet.iter (fun i -> cl := i :: !cl) closure;
  print_endline ("Closure is " ^ catmap " " si !cl);
  *)
  let revariable = mk_remap syms.counter revariable in

  BidSet.iter begin fun i ->
    let old_parent = Flx_bsym_table.find_parent bsym_table i in
    let new_parent: bid_t option =
      match old_parent with
      | None -> assert false
      | Some p ->
        if p = index then parent
        else Some (Hashtbl.find revariable p)
    in
    let k = Hashtbl.find revariable i in
    reparent1 syms uses bsym_table relabel varmap revariable
      caller_vs callee_vs_len i new_parent k rescan_flag
  end closure;
  if syms.compiler_options.print_flag then begin
    Hashtbl.iter
    (fun i j ->
      print_endline ("//Reparent " ^ string_of_bid j ^ " <-- " ^
        string_of_bid i)
    )
    revariable
  end
  ;
  revariable

(* NOTE! when we specialise a routine, calls to the same
  routine (polymorphically recursive) need not end up
  recursive. They're only recursive if they call the
  original routine with the same type specialisations
  as the one we're making here.

  In particular a call is recursive if, and only if,
  it is fully polymorphic (that is, just resupplies
  all the original type variables). In that case,
  recursion is preserved by specialisation.

  However recursion can also be *introduced* by specialisation
  where it didn't exist before!

  So remapping function indices has to be conditional.

  Note that calls to children HAVE to be remapped
  because of reparenting -- the original kids
  are no longer reachable! But this is no problem
  because the kid's inherited type variables are
  specialised away: you can't supply a kid with
  type variable instances distinct from the kid's
  parents variables (or the kid would refer to the
  stack from of a distinct function!)

  So the only problem is on self calls of the main
  routine, since they can call self either with
  the current specialisation or any other.
*)


let specialise_symbol syms uses bsym_table
  caller_vs callee_vs_len index ts parent relabel varmap rescan_flag
=
  try Hashtbl.find syms.transient_specialisation_cache (index,ts)
  with Not_found ->
    let k = fresh_bid syms.counter in

    (* First we must insert the symbol into the bsym_table before we can
     * continue. We'll update it again after we've processed the children. *)
    Flx_bsym_table.add bsym_table parent k
      (Flx_bsym_table.find bsym_table index);

    let revariable =
       reparent_children syms uses bsym_table
       caller_vs callee_vs_len index (Some k) relabel varmap rescan_flag []
    in

    (* Finally, reparent the symbol. *)
    reparent1 (syms:sym_state_t) uses bsym_table
      relabel varmap revariable
      caller_vs callee_vs_len index parent k rescan_flag;

    let caller_vars = map
      (fun (s,i) -> btyp_type_var (i, btyp_type 0))
      caller_vs
    in

    let ts' = vsplice caller_vars callee_vs_len ts in
    Hashtbl.add syms.transient_specialisation_cache (index,ts) (k,ts');
    k,ts'
