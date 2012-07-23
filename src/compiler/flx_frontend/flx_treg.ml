open Flx_types
open Flx_btype
open Flx_bbdcl
open Flx_mtypes2
open Flx_typing
open Flx_unify
open Flx_print
open Flx_exceptions
open Flx_util
open Flx_list
open List
open Flx_maps
open Flx_beta

let register_type_nr syms bsym_table t =
  (*
  if t <> t' then print_endline ("UNREDUCED TYPE! " ^ sbt bsym_table t ^ " <> " ^ sbt bsym_table t');
  *)
  match t with
  | BTYP_fix _
  | BTYP_tuple []
    -> ()
  | _
    ->
    let t = fold syms.counter t in
    if not (Hashtbl.mem syms.registry t)
    then begin
      let () = check_recursion t in
      let n = fresh_bid syms.counter in
      if syms.compiler_options.Flx_options.print_flag then
      print_endline ("//Register type " ^ string_of_bid n ^ ": " ^
        sbt bsym_table t);
      Hashtbl.add syms.registry t n
    end


let register_tuple syms bsym_table t =
  let t = fold syms.counter t in
  let record_tuple t =
    register_type_nr syms bsym_table t;
    try Hashtbl.replace syms.array_as_tuple_registry (Hashtbl.find syms.registry t) ()
    with Not_found -> ()
  in
  match t with
  | BTYP_tuple [] -> ()
  | BTYP_tuple [_] -> assert false

  | BTYP_tuple ts -> record_tuple t

  | BTYP_array (t',BTYP_unitsum n) ->
    let ts = rev_map (fun _ -> t') (nlist n) in
    record_tuple (btyp_tuple ts)

  | BTYP_record (n,ts) ->
    begin match t with
    | BTYP_tuple [] -> ()
    | _ -> record_tuple t
    end

  | _ -> assert false

let rec register_type_r ui syms bsym_table exclude sr t =
  let t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr t in
  (*
  let sp = String.make (length exclude * 2) ' ' in
  print_endline (sp ^ "Register type " ^ sbt sym_table t);
  if (mem t exclude) then print_endline (sp ^ "Excluded ..");
  *)
  if not (Hashtbl.mem syms.registry t) then
  if not (mem t exclude) then
  let rr t' = register_type_r ui syms bsym_table (t :: exclude) sr t' in
  let rnr t = register_type_nr syms bsym_table t in
  let t' = unfold t in
  (*
  print_endline (sp ^ "Unfolded type " ^ sbt sym_table t');
  *)
  match t' with
  | BTYP_void -> ()
  | BTYP_fix 0 -> ()
  | BTYP_fix i -> clierr sr ("[register_type_r] Fixpoint "^si i^" encountered")
  (*
  | BTYP_type_var (i,mt) -> clierr sr ("Attempt to register type variable " ^ si i ^":"^sbt sym_table mt)
  *)
  | BTYP_type_var (i,mt) ->
    print_endline ("Attempt to register type variable " ^ string_of_bid i ^
      ":" ^ sbt bsym_table mt)

  | BTYP_function (ps,ret) ->
    let ps = match ps with
    | BTYP_void -> btyp_tuple []
    | x -> x
    in
    rr ps;
    rr ret;
    rnr (btyp_function (ps,ret))

  | BTYP_cfunction (ps,ret) ->
    rr ps;
    rr ret;
    rnr t

  | BTYP_array (ps,ret) ->
    begin match ret with
    | BTYP_unitsum 0 | BTYP_void -> syserr sr "Unexpected array length 0"
(*
    | BTYP_unitsum 1 | BTYP_tuple [] -> syserr sr "Unexpected array length 1"
*)
    | BTYP_unitsum _ ->
      rr ps; rr ret; rnr t
    | _ -> rr ps; rr ret; rnr t
    (* | _ -> syserr sr ("Array index type must be unitsum, got " ^ sbt bsym_table ret) *)
    end

  | BTYP_tuple ps -> iter rr ps; rnr t

  | BTYP_record (n,ps) -> iter (fun (s,t)->rr t) ps; rnr t
  | BTYP_variant ps -> iter (fun (s,t)->rr t) ps; rnr t

  | BTYP_sum ps ->
    (* iter rr ps; *) (* should be driven by constructors *)
    rnr t

  | BTYP_unitsum k -> rnr t

  (* NOTE: pointer type is registered before the type it points
    to because it can be incomplete, whereas the type it
    points to may need a complete pointer type: this
    is always the case for recursion under a pointer
  *)

  (* pointer type is no longer registered, just us t* *)

  | BTYP_pointer t' -> rr t'

  | BTYP_inst (i,ts)->
    iter rr ts;

    let bsym =
      try Flx_bsym_table.find bsym_table i with Not_found ->
        failwith ("[register_type_r] Can't find index " ^ string_of_bid i)
    in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_newtype (vs,r) ->
      let r' = tsubst vs ts r in
      rr r';
      rnr t

    | BBDCL_union (vs,cs) ->
      (*
      let cts = map snd cs in
      let cts = map (tsubst vs ts) cts in
      iter rr cts;
      *)
      rnr t

    | BBDCL_cstruct (vs,cs,_)
    | BBDCL_struct (vs,cs) ->
      let cts = map snd cs in
      let cts = map (tsubst vs ts) cts in
      iter rr cts;

      (* HACKERY HERE... We should NOT need to register
        constructors, etc, unless they're actually used
      *)
      (*
      if length cts > 1 then rnr (BTYP_tuple cts);
      *)

      (*
      let argt = btyp_tuple cts in
      rnr argt;                             (* argument tuple *)
      *)
      rnr t;
      (*
      rnr (BTYP_function (argt,t))         (* constructor as function *)
      *)

    | BBDCL_external_type (vs,bquals,_,_)  -> 
     (* instantiate the type too *)
      ui i ts; rnr t;
      begin (* if there is an associated shape required, we have to register the type *)
       let handle_qual bqual = match bqual with
        | `Bound_needs_shape t ->
          (*
          print_endline ("Needs shape (uninstantiated) " ^ sbt bsym_table t);
          *)
          (*
          let varmap = mk_varmap vs ts in
          let t = varmap_subst varmap t in
          *)
          let t' = tsubst vs ts t in
          (*
          print_endline ("Needs shape (instantiated) " ^ sbt bsym_table t);
          *)
          rr t'
        | _ -> ()
        in
        let rec aux quals = match quals with
        | [] -> ()
        | h :: t -> handle_qual h; aux t
        in aux bquals
      end

    | _ ->
      clierr sr
      (
        "[register_type_r] expected type declaration, got " ^
        string_of_bbdcl bsym_table (Flx_bsym.bbdcl bsym) i
      )
    end

  | _ ->  ()
    (*
    clierr sr
    (
      "Unexpected kind in register type: " ^
      sbt sym_table t
    )
    *)
