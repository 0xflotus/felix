(*
This module is the instantiator. It is responsible for building
a list of all polymorphic entities in the program, and for each
one listing the bindings of the type variables to concrete
type which are actually used in the program.

A recursive descent from the non-polymorphic roots of the program
tracks type variable substitutions along the call graph,
this ensures all polymorphic entities are fully monomorphised.

This code does not actually monomorphise the program, it just
generates a list of all the instantiations.
*)
open Flx_util
open Flx_ast
open Flx_types
open Flx_btype
open Flx_bexpr
open Flx_bexe
open Flx_bparameter
open Flx_bbdcl
open Flx_set
open Flx_mtypes2
open Flx_print
open Flx_typing
open List
open Flx_unify
open Flx_treg
open Flx_exceptions
open Flx_maps
open Flx_prop
open Flx_beta

let dummy_sr = Flx_srcref.make_dummy "[flx_inst] generated"

let null_table = Hashtbl.create 3

let add_inst syms bsym_table ref_insts1 (i,ts) =
  iter (fun t -> match t with 
    | BTYP_void -> 
      let sym = Flx_bsym_table.find bsym_table i in
      let name = Flx_bsym.id sym in
      print_endline ("Attempt to register instance " ^ name ^ ": " ^ si i ^ "[" ^
      catmap ", " (sbt bsym_table) ts ^ "]")
(*
      ; failwith "Attempt to instantiate type variable with type void"
*)
    | _ -> ()
    )
  ts;
    (*
    print_endline ("Attempt to register instance " ^ si i ^ "[" ^
    catmap ", " (sbt bsym_table) ts ^ "]");
    *)
  let ts = map (fun t -> beta_reduce "flx_inst: add_inst" syms.Flx_mtypes2.counter bsym_table dummy_sr t) ts in

  let i,ts = Flx_typeclass.fixup_typeclass_instance syms bsym_table i ts in
    (*
    print_endline ("remapped to instance " ^ si i ^ "[" ^
    catmap ", " (sbt bsym_table) ts ^ "]");
    *)
  let ts = List.map (normalise_tuple_cons bsym_table) ts in
  let x = i, ts in
  let has_variables =
    fold_left
    (fun truth t -> truth ||
      try var_occurs bsym_table t
      with _ -> failwith ("[add_inst] metatype in var_occurs for " ^ sbt bsym_table t)
    )
    false
    ts
  in
  if has_variables then
  failwith
  (
    "Attempt to register instance " ^ string_of_bid i ^ "[" ^
    catmap ", " (sbt bsym_table) ts ^
    "] with type variable in a subscript"
  )
  ;
  if not (FunInstSet.mem x !ref_insts1)
  && not (Hashtbl.mem syms.instances x)
  then begin
    ref_insts1 := FunInstSet.add x !ref_insts1
  end

let rec process_expr syms bsym_table ref_insts1 hvarmap sr ((e,t) as be) =
  (*
  print_endline ("Process expr " ^ sbe sym_table be ^ " .. raw type " ^ sbt bsym_table t);
  print_endline (" .. instantiated type " ^ sbt sym_table (varmap_subst hvarmap t));
  *)
  let ue e = process_expr syms bsym_table ref_insts1 hvarmap sr e in
  let ui i ts = add_inst syms bsym_table ref_insts1 (i,ts) in
  let ut t = register_type_r ui syms bsym_table [] sr t in
  let vs t = varmap_subst hvarmap t in
  let t' = vs t in
  ut t'
  ;
  (* CONSIDER DOING THIS WITH A MAP! *)
  begin match e with
  | BEXPR_not e
  | BEXPR_deref e
  | BEXPR_get_n (_,e)
  | BEXPR_match_case (_,e)
  | BEXPR_case_arg (_,e)
  | BEXPR_case_index e
    -> ue e

  | BEXPR_apply_prim (index,ts,a)
  | BEXPR_apply_direct (index,ts,a)
  | BEXPR_apply_struct (index,ts,a)
  | BEXPR_apply_stack (index,ts,a)
  | BEXPR_apply ((BEXPR_closure (index,ts),_),a) ->
    (*
    print_endline "apply direct";
    *)
    let bsym =
      try Flx_bsym_table.find bsym_table index with Not_found ->
        failwith ("[process_expr(apply instance)] Can't find index " ^
          string_of_bid index)
    in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (_,_,_,BTYP_void,_) ->
      failwith "Use of mangled procedure in expression! (should have been lifted out)"

    (* function type not needed for direct call *)
    | BBDCL_external_fun _
    | BBDCL_fun _
    | BBDCL_nonconst_ctor _
      ->
      let ts = map vs ts in
      ui index ts; ue a

    (* the remaining cases are struct/variant type constructors,
    which probably don't need types either .. fix me!
    *)
    (* | _ -> ue f; ue a *)
    | _ ->
      (*
      print_endline "struct component?";
      *)
      ui index ts; ue a
    end

  | BEXPR_apply ((BEXPR_compose (f1, f2),_), e) ->
    failwith "Application of composition, should have been reduced away"

  | BEXPR_apply (e1,e2) ->
    (*
    print_endline "Simple apply";
    *)
    ue e1; ue e2

  (* Note: not clear this will work, without the same special casing as apply
   * above
   * Also note: this is a closure not directly applied.
   *)
  | BEXPR_compose (e1,e2) ->
    (*
    print_endline "Simple compose";
    *)
    ue e1; ue e2

  | BEXPR_tuple es ->
    iter ue es;
    register_tuple syms bsym_table (vs t)

  | BEXPR_tuple_head e ->
    ue e

  | BEXPR_tuple_tail e ->
    ue e;
    register_tuple syms bsym_table (vs t) (* NOTE: this is the type of the tail! *)

  | BEXPR_tuple_cons (eh, et) ->
    ue eh; ue et; 
    register_tuple syms bsym_table (vs t)

  | BEXPR_record es ->
    let ss,es = split es in
    iter ue es;
    register_tuple syms bsym_table (vs t)

  | BEXPR_variant (s,e) ->
    ue e

  | BEXPR_case (_,t) -> ut (vs t)

  | BEXPR_ref (i,ts)
  | BEXPR_name (i,ts)
  | BEXPR_closure (i,ts)
    ->
    (* substitute out display variables *)
    (*
    print_endline ("Raw Variable " ^ si i ^ "[" ^ catmap "," (sbt bsym_table) ts ^ "]");
    *)
    let ts = map vs ts in
    (*
    print_endline ("Variable with mapped ts " ^ si i ^ "[" ^ catmap "," (sbt bsym_table) ts ^ "]");
    *)
    ui i ts;
    (*
    print_endline "Instance done";
    *)
    iter ut ts
    (*
    ;
    print_endline "ts done";
    *)

  | BEXPR_new e -> ue e
  | BEXPR_class_new (t,e) -> ut t; ue e
  | BEXPR_address e -> ue e
  | BEXPR_likely e -> ue e
  | BEXPR_unlikely e -> ue e
  | BEXPR_literal _ -> ()
  | BEXPR_expr (_,t) -> ut t
  | BEXPR_range_check (e1,e2,e3) -> ue e1; ue e2; ue e3
  | BEXPR_coerce (e,t) -> ue e; ut t
  end

and process_exe syms bsym_table ref_insts1 ts hvarmap exe =
  let ue sr e = process_expr syms bsym_table ref_insts1 hvarmap sr e in
  let uis i ts = add_inst syms bsym_table ref_insts1 (i,ts) in
  let ui i = uis i ts in
  (*
  print_endline ("processing exe " ^ string_of_bexe sym_table bsym_table 0 exe);
  print_endline ("With ts = " ^ catmap "," (sbt bsym_table) ts);
  *)
  (* TODO: replace with a map *)
  match exe with
  | BEXE_axiom_check _ -> assert false
  | BEXE_call_prim (sr,i,ts,e2)
  | BEXE_call_direct (sr,i,ts,e2)
  | BEXE_jump_direct (sr,i,ts,e2)
  | BEXE_call_stack (sr,i,ts,e2)
    ->
    let ut t = register_type_r uis syms bsym_table [] sr t in
    let vs t = varmap_subst hvarmap t in
    let ts = map vs ts in
    iter ut ts;
    uis i ts;
    ue sr e2

  | BEXE_call (sr,e1,e2)
  | BEXE_jump (sr,e1,e2)
    -> ue sr e1; ue sr e2

  | BEXE_assert (sr,e)
  | BEXE_ifgoto (sr,e,_)
  | BEXE_fun_return (sr,e)
  | BEXE_yield (sr,e)
    ->
      ue sr e

  | BEXE_axiom_check2 (sr,_,e1,e2)
  | BEXE_assert2 (sr,_,e1,e2)
    ->
     begin match e1 with Some e -> ue sr e | None -> () end;
     ue sr e2

  | BEXE_init (sr,i,e) ->
    (*
    print_endline ("[flx_inst] Initialisation " ^ si i ^ " := " ^ sbe sym_table bsym_table e);
    *)
    let vs' = Flx_bsym_table.find_bvs bsym_table i in
    (*
    print_endline ("vs=" ^ catmap "," (fun (s,i)-> s^ "<" ^ si i ^ ">") vs');
    print_endline ("Input ts = " ^ catmap "," (sbt bsym_table) ts);
    print_endline ("Varmap = " ^ Hashtbl.fold
      (fun i k acc -> acc ^ "\n"^si i ^ " |-> " ^ sbt bsym_table k )
      hvarmap ""
    );
    *)
    let ts = map (fun (s,i) -> btyp_type_var (i, btyp_type 0)) vs' in
    let ts = map (varmap_subst hvarmap) ts in
    uis i ts; (* this is wrong?: initialisation is not use .. *)
    ue sr e

  | BEXE_assign (sr,e1,e2) -> ue sr e1; ue sr e2

  | BEXE_svc (sr,i) ->
    let vs' = Flx_bsym_table.find_bvs bsym_table i in
    let ts = map (fun (s,i) -> btyp_type_var (i, btyp_type 0)) vs' in
    let ts = map (varmap_subst hvarmap) ts in
    uis i ts

  | BEXE_catch (sr, s, t) -> 
    let ut t = register_type_r uis syms bsym_table [] sr t in
    ut t
  | BEXE_label _
  | BEXE_halt _
  | BEXE_trace _
  | BEXE_goto _
  | BEXE_code _
  | BEXE_nonreturn_code _
  | BEXE_comment _
  | BEXE_nop _
  | BEXE_proc_return _
  | BEXE_begin
  | BEXE_end
  | BEXE_try _
  | BEXE_endtry _
    -> ()

and process_exes syms bsym_table ref_insts1 ts hvarmap exes =
  iter (process_exe syms bsym_table ref_insts1 ts hvarmap) exes

and process_function syms bsym_table hvarmap ref_insts1 index sr argtypes ret exes ts =
  (*
  print_endline ("Process function " ^ si index);
  *)
  process_exes syms bsym_table ref_insts1 ts hvarmap exes ;
  (*
  print_endline ("Done Process function " ^ si index);
  *)

and process_inst syms bsym_table instps ref_insts1 i ts inst =
  let uis i ts = add_inst syms bsym_table ref_insts1 (i,ts) in
  let ui i = uis i ts in
  let bsym =
    try Flx_bsym_table.find bsym_table i
    with Not_found -> failwith ("[process_inst] Can't find index " ^
      string_of_bid i)
  in
  let do_reqs vs reqs =
    iter (
      fun (i, ts)->
      if i = dummy_bid then
        clierr (Flx_bsym.sr bsym) ("Entity " ^ Flx_bsym.id bsym ^
          " has uninstantiable requirements");
      uis i (map vs ts)
    )
    reqs
  in
  let ue hvarmap e =
    process_expr syms bsym_table ref_insts1 hvarmap (Flx_bsym.sr bsym) e
  in
  let rtr t = register_type_r uis syms bsym_table [] (Flx_bsym.sr bsym) t in
  let rtnr t = register_type_nr syms bsym_table t in
  if syms.compiler_options.Flx_options.print_flag then
  print_endline ("//Instance " ^ string_of_bid inst ^ "=" ^ Flx_bsym.id bsym ^
    "<" ^ string_of_bid i ^ ">[" ^
    catmap "," (sbt bsym_table) ts ^ "]");
  match Flx_bsym.bbdcl bsym with
  | BBDCL_invalid -> assert false
  | BBDCL_module -> ()
  | BBDCL_fun (props,vs,(ps,traint),ret,exes) ->
    let argtypes = Flx_bparameter.get_btypes ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    if instps || mem `Cfun props then begin
      iter (fun {pindex=i; ptyp=t} ->
        ui i;
        rtr (varmap_subst hvarmap t)
      )
      ps
    end;
    process_function
      syms
      bsym_table
      hvarmap
      ref_insts1
      i
      (Flx_bsym.sr bsym)
      argtypes
      ret
      exes
      ts

  | BBDCL_union (vs,ps) ->
    let argtypes = map (fun (_,_,t)->t) ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let tss = map (varmap_subst hvarmap) argtypes in
    iter rtr tss;
    rtnr (btyp_inst (i,ts))


  | BBDCL_cstruct (vs,ps, reqs) ->
    let argtypes = map snd ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let tss = map (varmap_subst hvarmap) argtypes in
    iter rtr tss;
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs;
    rtnr (btyp_inst (i,ts))

  | BBDCL_struct (vs,ps) ->
    let argtypes = map snd ps in
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let tss = map (varmap_subst hvarmap) argtypes in
    iter rtr tss;
    rtnr (btyp_inst (i,ts))

  | BBDCL_newtype (vs,t) ->
    rtnr t;
    rtnr (btyp_inst (i,ts))

  | BBDCL_val (vs,t,_) ->
    if length vs <> length ts
    then syserr (Flx_bsym.sr bsym)
    (
      "ts/vs mismatch instantiating variable " ^ Flx_bsym.id bsym ^ "<" ^
      string_of_bid i ^ ">, inst " ^ string_of_bid inst ^ ": vs = [" ^
      catmap ";" (fun (s,i)-> s ^ "<" ^ string_of_bid i ^ ">") vs ^ "], " ^
      "ts = [" ^
      catmap ";" (fun t->sbt bsym_table t) ts ^ "]"
    );
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let t = varmap_subst hvarmap t in
    rtr t

  | BBDCL_external_const (props,vs,t,_,reqs) ->
    (*
    print_endline "Register const";
    *)
    assert (length vs = length ts);
    (*
    if length vs <> length ts
    then syserr sr
    (
      "ts/vs mismatch index "^si i^", inst "^si inst^": vs = [" ^
      catmap ";" (fun (s,i)-> s ^"<"^si i^">") vs ^ "], " ^
      "ts = [" ^
      catmap ";" (fun t->sbt bsym_table t) ts ^ "]"
    );
    *)
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let t = varmap_subst hvarmap t in
    rtr t;
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs

  (* shortcut -- header and body can only require other header and body *)
  | BBDCL_external_code (vs,s,ikind,reqs)
    ->
    (*
    print_endline ("Handling requirements of header/body " ^ s);
    *)
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs

  | BBDCL_external_fun (_,vs,argtypes,ret,reqs,_,kind) ->
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs;

    begin match kind with
    | `Callback (argtypes_c,_) ->
        let ret = varmap_subst hvarmap ret in
        rtr ret;

        (* prolly not necessary .. *)
        let tss = map (varmap_subst hvarmap) argtypes in
        List.iter rtr tss;

        (* just to register 'address' .. lol *)
        let tss = map (varmap_subst hvarmap) argtypes_c in
        List.iter rtr tss

    | _ ->
        process_function
          syms
          bsym_table
          hvarmap
          ref_insts1
          i
          (Flx_bsym.sr bsym)
          argtypes
          ret
          []
          ts
    end

  | BBDCL_external_type (vs,_,_,reqs) ->
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in
    let vs t = varmap_subst hvarmap t in
    do_reqs vs reqs

  | BBDCL_const_ctor (vs,uidx,udt, ctor_idx, evs, etraint) -> ()

  | BBDCL_nonconst_ctor (vs,uidx,udt, ctor_idx, ctor_argt, evs, etraint) ->
    assert (length vs = length ts);
    let vars = map2 (fun (s,i) t -> i,t) vs ts in
    let hvarmap = hashtable_of_list vars in

    (* we don't register the union .. it's a uctor anyhow *)
    let ctor_argt = varmap_subst hvarmap ctor_argt in
    rtr ctor_argt

  | BBDCL_typeclass _ -> ()
  | BBDCL_instance (props,vs,con,tc,ts) -> ()
  | BBDCL_axiom -> ()
  | BBDCL_lemma -> ()
  | BBDCL_reduce -> ()

(*
  This routine creates the instance tables.
  There are 2 tables: instance types and function types (including procs)

  The type registry holds the types used.
  The instance registry holds a pair:
  (index, types)
  where index is the function or procedure index,
  and types is a list of types to instantiated it.

  The algorithm starts with a list of roots, being
  the top level init routine and any exported functions.
  These must be non-generic.

  It puts these into a set of functions to be examined.
  Then it begins examining the set by chosing one function
  and moving it to the 'examined' set.

  It registers the function type, and then
  examines the body.

  In the process of examining the body,
  every function or procedure call is examined.

  The function being called is added to the
  to be examined list with the calling type arguments.
  Note that these type arguments may include type variables
  which have to be replaced by their instances which are
  passed to the examination routine.

  The process continues until there are no unexamined
  functions left. The effect is to instantiate every used
  type and function.
*)

let instantiate syms bsym_table instps (root:bid_t) (bifaces:biface_t list) =
  Hashtbl.clear syms.instances;
  Hashtbl.clear syms.registry;

  (* empty instantiation registry *)
  let insts1 = ref FunInstSet.empty in

  (* append routine to add an instance *)
  let add_cand i ts = insts1 := FunInstSet.add (i,ts) !insts1 in

  (* add the root *)
  add_cand root [];

  (* add exported functions, and register exported types *)
  let ui i ts = add_inst syms bsym_table insts1 (i,ts) in
  iter
  (function
    | BIFACE_export_python_fun (_,x,_)
    | BIFACE_export_cfun (_,x,_)
    | BIFACE_export_fun (_,x,_) ->
      let bsym = Flx_bsym_table.find bsym_table x in
      begin match Flx_bsym.bbdcl bsym with
      | BBDCL_fun (props,_,(ps,_),_,_) ->
        begin match ps with
        | [] -> ()
        | [{ptyp=t}] -> register_type_r ui syms bsym_table [] (Flx_bsym.sr bsym) t
        | _ ->
          let t = btyp_tuple (Flx_bparameter.get_btypes ps) in
          register_type_r ui syms bsym_table [] (Flx_bsym.sr bsym) t;
          register_type_nr syms bsym_table t;
          register_tuple syms bsym_table t;
        end
      | _ -> assert false
      end;
      add_cand x []

    | BIFACE_export_type (sr,t,_) ->
      register_type_r ui syms bsym_table [] sr t
  )
  bifaces;

  (* NEW: if a symbol is monomorphic use its index as its instance! *)
  (* this is a TRICK .. saves remapping the root/exports, since they
     have to be monomorphic anyhow
  *)
  let add_instance i ts =
    let ts = List.map (normalise_tuple_cons bsym_table) ts in
    let n =
      match ts with
      | [] -> i
      | _ -> fresh_bid syms.counter
    in
    Hashtbl.add syms.instances (i,ts) n;
    n
  in

  while not (FunInstSet.is_empty !insts1) do
    let (index,vars) as x = FunInstSet.choose !insts1 in
    insts1 := FunInstSet.remove x !insts1;
    let inst = add_instance index vars in
    process_inst syms bsym_table instps insts1 index vars inst
  done


(* BUG!!!!! Abstract type requirements aren't handled!! *)
