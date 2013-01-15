open Flx_util
open Flx_list
open Flx_types
open Flx_btype
open Flx_bexpr
open Flx_bexe
open Flx_bparameter
open Flx_bbdcl
open Flx_mtypes2
open Flx_print
open Flx_typing
open Flx_name
open Flx_unify
open Flx_csubst
open Flx_exceptions
open Flx_display
open List
open Flx_ctypes
open Flx_cexpr
open Flx_maps
open Flx_pgen
open Flx_beta

module CS = Flx_code_spec
module L = Flx_literal

let string_of_string = Flx_string.c_quote_of_string


let get_var_frame syms bsym_table this index ts : string =
  let bsym_parent, bsym =
    try Flx_bsym_table.find_with_parent bsym_table index
    with Not_found ->
      failwith ("[get_var_frame(1)] Can't find index " ^ string_of_bid index)
  in
  match Flx_bsym.bbdcl bsym with
  | BBDCL_val (vs,t,(`Val | `Var | `Ref)) ->
      begin match bsym_parent with
      | None -> "ptf"
      | Some i ->
          if i <> this
          then "ptr" ^ cpp_instance_name syms bsym_table i ts
          else "this"
      end
  | BBDCL_val (vs,t,`Tmp) ->
     failwith ("[get_var_frame] temporaries aren't framed: " ^ Flx_bsym.id bsym)

  | _ -> failwith ("[get_var_frame] Expected name " ^ Flx_bsym.id bsym ^ " to be variable or value")

let get_var_ref syms bsym_table this index ts : string =
  let bsym_parent, bsym =
    try Flx_bsym_table.find_with_parent bsym_table index
    with Not_found ->
      failwith ("[get_var_ref] Can't find index " ^ string_of_bid index)
  in
  match Flx_bsym.bbdcl bsym with
  | BBDCL_val (vs,t,(`Val | `Var | `Ref)) ->
      begin match bsym_parent with
      | None -> "PTF " ^ cpp_instance_name syms bsym_table index ts
      | Some i ->
          (
            if i <> this
            then "ptr" ^ cpp_instance_name syms bsym_table i ts ^ "->"
            else ""
          ) ^ cpp_instance_name syms bsym_table index ts
      end

  | BBDCL_val (vs,t,`Tmp) ->
      cpp_instance_name syms bsym_table index ts

  | _ -> failwith ("[get_var_ref(3)] Expected name " ^ Flx_bsym.id bsym ^ " to be variable, value or temporary")

let get_ref_ref syms bsym_table this index ts : string =
  let bsym_parent, bsym =
    try Flx_bsym_table.find_with_parent bsym_table index
    with Not_found ->
      failwith ("[get_var_ref] Can't find index " ^ string_of_bid index)
  in
  match Flx_bsym.bbdcl bsym with
  | BBDCL_val (vs,t,(`Val | `Var | `Ref)) ->
      begin match bsym_parent with
      | None ->
          "PTF " ^ cpp_instance_name syms bsym_table index ts
      | Some i ->
          (
            if i <> this
            then "ptr" ^ cpp_instance_name syms bsym_table i ts ^ "->"
            else ""
          ) ^
          cpp_instance_name syms bsym_table index ts
      end

  | BBDCL_val (vs,t,`Tmp) ->
      cpp_instance_name syms bsym_table index ts

  | _ -> failwith ("[get_var_ref(3)] Expected name " ^ Flx_bsym.id bsym ^ " to be variable, value or temporary")

let nth_type ts i =
  try match ts with
  | BTYP_tuple ts -> nth ts i
  | BTYP_array (t,BTYP_unitsum n) -> assert (i<n); t
  | _ -> assert false
  with Not_found ->
    failwith ("Can't find component " ^ si i ^ " of type!")

(* dumb routine to know if we need parens around a type name when used
 * as a cast: if it's an identifier, no we don't, otherwise we have
 * to use an old style cast
 *)

let idchars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"

let isid x = 
  let isid_char ch = 
    try
      for i = 0 to String.length idchars - 1 do
        if ch = idchars.[i] then raise Not_found
      done;
      false
    with Not_found -> true
  in
  try 
    for i = 0 to String.length x - 1 do
      if not (isid_char x.[i]) then raise Not_found;
    done;
    true
  with _ -> false

let rec handle_get_n syms bsym_table rt ge' e t n ((e',t') as arg) =
(*
print_endline ("Handling a get-n in egen"^
  "\n  Expression          e=" ^ sbe bsym_table (e,t) ^ 
  "\n  Projection index:   n= " ^ si n ^ 
  "\n  Projection argument a = " ^ sbe bsym_table arg ^
  "\n"
);
*)
    let array_sum_offset_table = syms.array_sum_offset_table in
    let power_table = syms.power_table in
    let seq = syms.counter in
    let rtt' = rt t' in
    match rtt' with
    | BTYP_tuple ls  -> 
(*
      print_endline "expr arg has tuple type"; 
*)
      if islinear_type bsym_table rtt' then begin
        let sidx = Flx_ixgen.cal_symbolic_array_index bsym_table arg in
        let cidx = Flx_ixgen.render_index bsym_table ge' array_sum_offset_table seq sidx in
        (* now calculate the projection: this is given by 
             idx / a % b
             where a = product of sizes of first n  terms (or 1 if n=0)
             and b = size of term n

             Example:

             type 3 * 4 * 5: i,j,k
             encoding is 20i + 5j + k
             decoding is:
                 k = ijk / 1 % 5
                 j = ijk / 5 % 4
                 i = ijk / 20 % 3  [the %3 is not required here]

           SO: to get the n'th projection, where n=0 is i, n=1 is j, n=2 is k,
           numbering big endian digits left to right, we have to divide by
           the product of sizes of all the terms to its right: 

               size(n+1) * size(n+2) ... (size m) 
          
           where there are m digits. This is m - n - 1 terms.
           Here n ranges from 0 to m - 1, m - n thus ranges from m - 0 = m to m - (m - 1) = 1
           and so the number of terms ranges from m - 1 to 0
        *)
        assert (0 <= n && n < List.length ls);
        let rec aux ls i out = match ls with [] -> assert false | h :: t ->
           if i = 0 then out else aux t (i-1) (sizeof_linear_type bsym_table h * out)
        in 
        let a = aux (rev ls) (List.length ls - n - 1) 1 in
        let b = sizeof_linear_type bsym_table (List.nth ls n) in
(*
        let apart = if a = 1 then cidx else ce_infix "/" cidx (ce_atom (si a)) in
        let result = if n = List.length ls - 1 then apart else ce_infix "%" apart (ce_atom (si b)) in
*)
        let result = ce_infix "%" (ce_infix "/" cidx (ce_atom (si a))) (ce_atom (si b)) in
(*
print_endline ("Result= " ^ string_of_cexpr result);
*)
        result
      end
      else
        ce_dot (ge' arg) ("mem_" ^ si n)
    | BTYP_array (_,BTYP_unitsum _) ->
      begin match arg with
      | BEXPR_tuple _,_ -> print_endline "Failed to slice a tuple!"
      | _ -> ()
      end;
      ce_dot (ge' arg) ("data["^si n^"]")
    | BTYP_record (name,es) ->
      let field_name,_ =
        try nth es n
        with Not_found ->
          failwith "[flx_egen] Woops, index of non-existent struct field"
      in
      ce_dot (ge' arg) (cid_of_flxid field_name)

    | BTYP_inst (i,_) ->
      begin match Flx_bsym_table.find_bbdcl bsym_table i with
      | BBDCL_cstruct (_,ls,_)
      | BBDCL_struct (_,ls) ->
        let name,_ =
          try nth ls n
          with _ ->
            failwith "Woops, index of non-existent struct field"
        in
        ce_dot (ge' arg) (cid_of_flxid name)

      | _ -> failwith ("[flx_egen] Expr "^sbe bsym_table (e,t)^ " type " ^ sbt bsym_table t ^
        " object " ^ sbe bsym_table arg ^ " type " ^ sbt bsym_table t' ^ 
        " Instance of " ^string_of_int i^ " expected to be (c)struct")
      end

    | BTYP_pointer (BTYP_record (name,es)) ->
      let field_name,_ =
        try nth es n
        with Not_found ->
          failwith "[flx_egen] Woops, index of non-existent struct field"
      in
      ce_prefix "&" (ce_arrow (ge' arg) (cid_of_flxid field_name))

    | BTYP_pointer (BTYP_inst (i,_)) ->
      begin match Flx_bsym_table.find_bbdcl bsym_table i with
      | BBDCL_cstruct (_,ls,_)
      | BBDCL_struct (_,ls) ->
        let name,_ =
          try nth ls n
          with _ ->
            failwith "Woops, index of non-existent struct field"
        in
        ce_prefix "&" (ce_arrow (ge' arg) (cid_of_flxid name))

      | _ -> failwith "[flx_egen] Instance expected to be (c)struct"
      end

    | BTYP_pointer (BTYP_array _) ->
      ce_prefix "&" (ce_arrow (ge' arg) ("data["^si n^"]"))

    | BTYP_pointer (BTYP_tuple _) ->
      ce_prefix "&" (ce_arrow (ge' arg) ("mem_" ^ si n))

    | BTYP_tuple_cons (t1,t2) ->
(*
      print_endline ("Tuple cons, projection " ^ si n);
*)
      (* NOTE: Won't work for compact linear types! *)
      ce_dot (ge' arg) ("mem_" ^ si n)

    | _ -> assert false (* ce_dot (ge' e) ("mem_" ^ si n) *)

and gen_expr'
  syms
  bsym_table
  this
  this_vs
  this_ts
  sr
  (e,t)
  : cexpr_t
=
(*
  print_endline ("Gen_expr': " ^ sbe bsym_table (e,t));
*)
  match e with
  (* replace heap allocation of a unit with NULL pointer *)
  | BEXPR_new (BEXPR_tuple [],_) -> ce_atom "0/*NULL*/"
  | _ ->
  if length this_ts <> length this_vs then begin
    failwith
    (
      "[gen_expr} wrong number of args, expected vs = " ^
      si (length this_vs) ^
      ", got ts=" ^
      si (length this_ts)
    )
  end;

  let ge = gen_expr syms bsym_table this this_vs this_ts sr in
  let ge' = gen_expr' syms bsym_table this this_vs this_ts sr in
  let tsub t = beta_reduce "flx_egen" syms.Flx_mtypes2.counter bsym_table sr (tsubst this_vs this_ts t) in
  let tn t = cpp_typename syms bsym_table (tsub t) in

  (* NOTE this function does not do a reduce_type *)
  let raw_typename t =
    cpp_typename
    syms
    bsym_table
    (beta_reduce "flx_egen2" syms.Flx_mtypes2.counter bsym_table sr (tsubst this_vs this_ts t))
  in
  let ge_arg ((x,t) as a) =
    let t = tsub t in
    match t with
    | BTYP_tuple [] -> ""
    | _ -> ge a
  in
  let ge_carg ps ts vs a =
    match a with
    | BEXPR_tuple xs,_ ->
      (*
      print_endline ("Arg to C function is tuple " ^ sbe bsym_table a);
      *)
      fold_left2
      (fun s ((x,t) as xt) {pindex=ix} ->
        let x =
          if Hashtbl.mem syms.instances (ix,ts)
          then ge_arg xt
          else ""
        in
        if String.length x = 0 then s else
        s ^
        (if String.length s > 0 then ", " else "") ^ (* append a comma if needed *)
        x
      )
      ""
      xs ps

    | _,tt ->
      let k = List.length ps in
      let tt = beta_reduce "flx_egen3" syms.Flx_mtypes2.counter bsym_table sr  (tsubst vs ts tt) in
      (* NASTY, EVALUATES EXPR MANY TIMES .. *)
      let n = ref 0 in
      fold_left
      (fun s i ->
        (*
        print_endline ( "ps = " ^ catmap "," (fun (id,(p,t)) -> id) ps);
        print_endline ("tt=" ^ sbt bsym_table tt);
        *)
        let t = nth_type tt i in
        let a' = bexpr_get_n t (bexpr_unitsum_case i k,a) in
        let x = ge_arg a' in
        incr n;
        if String.length x = 0 then s else
        s ^ (if String.length s > 0 then ", " else "") ^ x
      )
      ""
      (nlist k)
  in
  let our_display = get_display_list bsym_table this in
  let our_level = length our_display in
  let rt t = beta_reduce "flx_egen4" syms.Flx_mtypes2.counter bsym_table sr (tsubst this_vs this_ts t) in
  let array_sum_offset_table = syms.array_sum_offset_table in
  let power_table = syms.power_table in
  let seq = syms.counter in
  let t = rt t in
  match t with
  (* This is now required for arrays of length 1 *)
  | BTYP_tuple [] -> ce_atom "(::flx::rtl::unit())/*UNIT TUPLE?*/"
(*
      clierr sr
     ("[egen] In "^sbe bsym_table (e,t)^":\nunit value required, should have been eliminated")
*)

     (* ce_atom ("UNIT_ERROR") *)
  | _ ->
  match e with
  | BEXPR_expr (s,_) -> ce_top (s)

  | BEXPR_case_index e -> Flx_vgen.gen_get_case_index ge' bsym_table e

  | BEXPR_range_check (e1,e2,e3) ->
     let f,sl,sc,el,ec = Flx_srcref.to_tuple sr in
     let f = ce_atom ("\""^ f ^"\"") in
     let sl = ce_atom (si sl) in
     let sc = ce_atom (si sc) in
     let el = ce_atom (si el) in
     let ec = ce_atom (si ec) in
     let sref = ce_call (ce_atom "flx::rtl::flx_range_srcref_t") [f;sl;sc;el;ec] in
     let cf = ce_atom "__FILE__" in
     let cl = ce_atom "__LINE__" in
     let args : cexpr_t list =
       [ ge' e1 ; ge' e2; ge' e3; sref; cf; cl]
     in
     ce_call (ce_atom "flx::rtl::range_check") args

(* linear index of linear  type .. handle directly *)
  | BEXPR_get_n ((_,idxt) as idx, (_,(BTYP_array (v,aixt) as at) as a)) 
    when islinear_type bsym_table at ->
(*
    print_endline "Projection of linear type!";
*)
    assert (idxt = aixt);
    assert (islinear_type bsym_table v);
    let array_value_size = sizeof_linear_type bsym_table v in

    let sidx = Flx_ixgen.cal_symbolic_array_index bsym_table idx in
    let sarr = Flx_ixgen.cal_symbolic_array_index bsym_table a in
(*
print_endline ("Symbolic index = " ^ Flx_ixgen.print_index bsym_table sidx );
print_endline ("Symbolic array = " ^ Flx_ixgen.print_index bsym_table sarr );
*)
    let cidx = Flx_ixgen.render_index bsym_table ge' array_sum_offset_table seq sidx in
(*
print_endline ("rendered lineralised index .. C index = " ^ string_of_cexpr cidx);
*)
    let carr = Flx_ixgen.render_index bsym_table ge' array_sum_offset_table seq sarr in
    let ipow = Flx_ixgen.get_power_table bsym_table power_table array_value_size in
    let cdiv = ce_array (ce_atom ipow) cidx  in
    let result = ce_infix "%" (ce_infix "/" carr cdiv) (ce_atom (si array_value_size)) in
    result

(* Ok, the value type isn't linear, just linearise the index *)
  | BEXPR_get_n ((_,idxt) as idx, (_,(BTYP_array (_,aixt) as at) as a)) ->
(*
print_endline ("Get n .. array " ^ sbe bsym_table a);
print_endline ("array type " ^ sbt bsym_table at);
*)
    assert (idxt = aixt); 
(*
print_endline ("index type = " ^ sbt bsym_table idxt );
print_endline ("index value = " ^ sbe bsym_table idx );
*)
    let sidx = Flx_ixgen.cal_symbolic_array_index bsym_table idx in
(*
print_endline ("Symbolic index = " ^ Flx_ixgen.print_index bsym_table sidx );
*)
    let cidx = Flx_ixgen.render_index bsym_table ge' array_sum_offset_table seq sidx in
(*
print_endline ("rendered lineralised index .. C index = " ^ string_of_cexpr cidx);
*)
    ce_array (ce_dot (ge' a) "data") cidx 


(* ordinary index .. *)
  | BEXPR_get_n ((BEXPR_case (n,_),_),(e',t' as e2)) ->
(*
print_endline "gen_expr': BEXPR_get_n (first)";
*)
    handle_get_n syms bsym_table rt ge' e t n e2 

  | BEXPR_get_n _ -> clierr sr "Can't handle generalised get_n yet"

  | BEXPR_tuple_cons ((eh',th' as xh'), (et', tt' as xt')) ->
(*
    print_endline ("Tuple_cons (" ^ sbe bsym_table xh' ^ " , " ^ sbe bsym_table xt');
    print_endline ("Type " ^ sbt bsym_table t);
    print_endline ("Head Type " ^ sbt bsym_table th');
    print_endline ("Tail Type " ^ sbt bsym_table tt');
*)
    let ntt = normalise_tuple_cons bsym_table tt' in
    let tts = match ntt with
    | BTYP_tuple tts -> tts
    | _ -> assert false
    in 
    let n = List.length tts in
    let counter = ref 0 in
(* NOTE: this is a hack! Doen't handle arrays. The code generated here
   is ALWAYS correct BUT we may have neglected to create a tuple
   constructor, because the scan for BEXPR_tuple is already done. 
*)
    let es = match et' with
    | BEXPR_tuple es -> es 
    | _ -> 
      List.map (fun t-> 
      let i = !counter in incr counter;
      BEXPR_get_n 
      (
        (BEXPR_case (i,BTYP_unitsum n), BTYP_unitsum n), 
        xt'
      ),t)
      tts
    in
    let es = xh' :: es in
    let t = normalise_tuple_cons bsym_table t in
    let e = BEXPR_tuple es, t in
(*
print_endline ("Normalised expression " ^ sbe bsym_table e);
*)
    ge' e

  | BEXPR_tuple_head (e',t' as x') ->
(*
    print_endline ("Tuple head of expression " ^ sbe bsym_table x');
    print_endline ("Type " ^ sbt bsym_table t');
*)
    let t'' = normalise_tuple_cons bsym_table t' in
(*
    print_endline ("Normalised Type " ^ sbt bsym_table t');
    print_endline ("Tail Type " ^ sbt bsym_table t);
*)
    begin match t'' with 
    | BTYP_tuple [] -> assert false
    | BTYP_tuple ts -> 
      let eltt = List.hd ts in
      let n = List.length ts in
      ge' (bexpr_get_n eltt (bexpr_unitsum_case 0 n,x'))

    | _ -> 
      print_endline ("Expected head to be tuple, got " ^ sbt bsym_table t' ^ " ->(normalised)-> " ^ sbt bsym_table t'');
      assert false
    end

  | BEXPR_tuple_tail (e',t' as x') ->
(*
    print_endline ("Tuple tail of expression " ^ sbe bsym_table x');
    print_endline ("Type " ^ sbt bsym_table t');
*)
    let t'' = normalise_tuple_cons bsym_table t' in
(*
    print_endline ("Normalised Type " ^ sbt bsym_table t');
    print_endline ("Tail Type " ^ sbt bsym_table t);
*)
    begin match t'' with 
    | BTYP_tuple ts -> 
      let n = List.length ts in
      let counter = ref 0 in
      let es = 
        List.map (fun t-> 
          incr counter; 
          let index = bexpr_unitsum_case (!counter) n in
          bexpr_get_n t (index, x')
       ) 
       (List.tl ts) 
      in
      let tail = match es with [x] -> x | es -> bexpr_tuple t es in
      ge' tail
    | _ -> 
      print_endline ("Expected tail to be tuple, got " ^ sbt bsym_table t' ^ " ->(normalised)-> " ^ sbt bsym_table t'');
      assert false
    end

  | BEXPR_match_case (n,((e',t') as e)) ->
    let t' = beta_reduce "flx_egen get_n: match_case" syms.Flx_mtypes2.counter bsym_table sr t' in
    let x = Flx_vgen.gen_get_case_index ge' bsym_table e in
    ce_infix "==" x (ce_atom (si n))

  | BEXPR_not (BEXPR_match_case (n,((e',t') as e)),_) ->
    let t' = beta_reduce "flx_egen: not" syms.Flx_mtypes2.counter bsym_table sr t' in
    let x = Flx_vgen.gen_get_case_index ge' bsym_table e in
    ce_infix "!=" x (ce_atom (si n))

  | BEXPR_not e -> ce_prefix "!" (ge' e)

  | BEXPR_case_arg (n,e) ->
(*
    print_endline ("flx_egen[ge_carg]: Decoding nonconst ctor type " ^ sbt bsym_table t);
*)
    Flx_vgen.gen_get_case_arg ge' tn bsym_table n e
    (*
    begin match t with (* t is the result of the whole expression *)
    | BTYP_function _ ->
      let cast = tn t in
      ce_cast cast (ce_dot (ge' e) "data")
    | _ ->
      let cast = tn t ^ "*" in
      ce_prefix "*" (ce_cast cast (ce_dot (ge' e) "data"))
    end
    *)

  | BEXPR_deref ((BEXPR_ref (index,ts)),BTYP_pointer t) ->
    ge' (bexpr_name t (index,ts))

  | BEXPR_address e -> ce_prefix "&" (ge' e)

  | BEXPR_deref e ->
    (*
    let cast = tn t ^ "*" in
    *)
    (*
    ce_prefix "*" (ce_cast cast (ce_dot (ge' e) "get_data()"))
    *)
    (*
    ce_prefix "*" (ce_cast cast (ge' e) )
    *)
    ce_prefix "*" (ge' e)

  (* fun reductions .. probably should be handled before
     getting here
  *)

  | BEXPR_likely e ->
    begin match t with
    | BTYP_unitsum 2 ->
      ce_atom ("FLX_LIKELY("^ge e^")")
    | _ -> ge' e
    end

  | BEXPR_unlikely e ->
    begin match t with
    | BTYP_unitsum 2 ->
      ce_atom ("FLX_UNLIKELY("^ge e^")")
    | _ -> ge' e
    end

  | BEXPR_new e ->
    let ref_type = tn t in
    let _,t' = e in
    let pname = shape_of syms bsym_table tn t' in
    let typ = tn t' in
    let frame_ptr = ce_new 
        [ ce_atom "*PTF gcp"; ce_atom pname; ce_atom "true"] 
        typ 
        [ge' e]
    in
    ce_cast ref_type frame_ptr

(* class new constructs an object _in place_ on the heap, unlike ordinary
 * new, which just makes a copy of an existing value.
 *)
  | BEXPR_class_new (t,a) ->
    let ref_type = tn t in
print_endline ("Generating class new for t=" ^ ref_type);
    let args = match a with
    | BEXPR_tuple [],_ -> []
    | BEXPR_tuple es,_ -> map ge' es
    | _ -> [ge' a]
    in
    ce_new [ce_atom "*PTF gcp";ce_atom (ref_type^"_ptr_map"); ce_atom "true"] ref_type args

  | BEXPR_literal {Flx_literal.c_value=v} ->
    ce_atom v
    (*
    let t = tn t in
    ce_cast t  (ce_atom (cstring_of_literal v))
    *)

  (* A case tag: this is a variant value for any variant case
   * which has no (or unit) argument: can't be used for a case
   * with an argument. This is here for constant constructors,
   * particularly enums.
   *)
  | BEXPR_case (v,t') ->
    if Flx_btype.islinear_type bsym_table t then begin
(*
print_endline ("egen:BEXPR_case: index type = " ^ sbt bsym_table t );
print_endline ("egen:BEXPR_case: index value = " ^ sbe bsym_table (e,t));
*)
      let sidx = Flx_ixgen.cal_symbolic_array_index bsym_table (e,t) in
(*
print_endline ("egen:BEXPR_case: Symbolic index = " ^ Flx_ixgen.print_index bsym_table sidx );
*)
      let cidx = Flx_ixgen.render_index bsym_table ge' array_sum_offset_table seq sidx in
(*
print_endline ("egen:BEXPR_case: rendered lineralised index .. C index = " ^ string_of_cexpr cidx);
*)
      cidx
    end
    else
(*
print_endline ("make const ctor, union type = " ^ sbt bsym_table t' ^ 
" ctor#= " ^ si v ^ " union type = " ^ sbt bsym_table t);
*)
    Flx_vgen.gen_make_const_ctor bsym_table (e,t)
    (* 
    begin match unfold t' with
    | BTYP_unitsum n ->
      if v < 0 or v >= n
      then
        failwith
        (
          "Invalid case index " ^ si v ^
          " of " ^ si n ^ " cases  in unitsum"
        )
     else ce_atom (si v)

    | BTYP_sum ls ->
       let s =
         let n = length ls in
         if v < 0 or v >= n
         then
           failwith
           (
             "Invalid case index " ^ si v ^
             " of " ^ si n ^ " cases"
           )
         else let t' = nth ls v in
         if t' = btyp_tuple []
         then (* closure of const ctor is just the const value ???? *)
           if is_unitsum t then
             si v
           else
             "::flx::rtl::_uctor_(" ^ si v ^ ",0)"
         else
           failwith
           (
              "Can't handle closure of case " ^
              si v ^
              " of " ^
              sbt bsym_table t
           )
       in ce_atom s

    | _ -> failwith "Case tag must have sum type"
    end
*)

  | BEXPR_name (index,ts') ->
    let bsym_parent, bsym =
      try Flx_bsym_table.find_with_parent bsym_table index
      with Not_found ->
        syserr sr ("[gen_expr(name)] Can't find <" ^ string_of_bid index ^ ">")
    in
    let ts = map tsub ts' in
    begin match Flx_bsym.bbdcl bsym with
      | BBDCL_val (_,BTYP_function (BTYP_void,_),`Val)  ->
          let ptr = (get_var_ref syms bsym_table this index ts) in
          ce_call (ce_arrow (ce_atom ptr) "apply") []

      | BBDCL_val (_,t,_) ->
          ce_atom (get_var_ref syms bsym_table this index ts)

      | BBDCL_const_ctor (vs,uidx,udt, ctor_idx, evs, etraint) ->
        Flx_vgen.gen_make_const_ctor bsym_table (e,t)

      | BBDCL_external_const (props,_,_,ct,_) ->
        if mem `Virtual props then
          print_endline ("Instantiate virtual const " ^ Flx_bsym.id bsym ^ "["^catmap "," (sbt bsym_table) ts^"]")
        ;
        begin match ct with
        | CS.Identity -> syserr sr ("Nonsense Idendity const" ^ Flx_bsym.id bsym)
        | CS.Virtual -> clierr2 sr (Flx_bsym.sr bsym) ("Instantiate virtual const " ^ Flx_bsym.id bsym)
        | CS.Str c
        | CS.Str_template c when c = "#srcloc" ->
           let f, l1, c1, l2, c2 = Flx_srcref.to_tuple sr in
           ce_atom ("flx::rtl::flx_range_srcref_t(" ^
             string_of_string f ^ "," ^
             si l1 ^ "," ^
             si c1 ^ "," ^
             si l2 ^ "," ^
             si c2 ^ ")"
           )

        | CS.Str c when c = "#this" ->
          begin match bsym_parent with
          | None -> clierr sr "Use 'this' outside class"
          | Some p ->
            let name = cpp_instance_name syms bsym_table p ts in
            (*
            print_endline ("class = " ^ si p ^ ", instance name = " ^ name);
            *)
            ce_atom("ptr"^name)
          end

        | CS.Str c
        | CS.Str_template c when c = "#memcount" ->
          begin match ts with
          | [BTYP_void] -> ce_atom "0"
          | [BTYP_unitsum n]
          | [BTYP_array (_,BTYP_unitsum n)] -> ce_atom (si n)
          | [BTYP_sum ls] 
          | [BTYP_tuple ls] -> let n = length ls in ce_atom (si n)
          | [BTYP_inst (i,_)] ->
            begin match Flx_bsym_table.find_bbdcl bsym_table i with
              | BBDCL_struct (_,ls) -> let n = length ls in ce_atom (si n)
              | BBDCL_cstruct (_,ls,_) -> let n = length ls in ce_atom (si n)
              | BBDCL_union (_,ls) -> let n = length ls in ce_atom (si n)
              | _ ->
                clierr sr (
                  "#memcount function requires type with members to count, got: " ^
                  sbt bsym_table (hd ts)
                )
            end
          | _ ->
            clierr sr (
              "#memcount function requires type with members to count, got : " ^
              sbt bsym_table (hd ts)
            )
          end
        | CS.Str_template c when c = "#arrayindexcount" ->
          (* we do hacked up processing of sums of unitsums here, to allow for
             the implicit flattening of array indices. 
             Also we allow a list in preparation for rank K arrays.
          *)
          begin try
            let n = fold_left (fun acc elt -> acc * Flx_btype.int_of_linear_type bsym_table elt) 1 ts in
            ce_atom (si n)
          with Invalid_int_of_unitsum ->
            clierr sr (
              "#arrayindexcountfunction requires type which can be used as array index, got: " ^
              catmap "," (sbt bsym_table) ts
            )
          end
        | CS.Str c -> ce_expr "expr" c
        | CS.Str_template c ->
          let ts = map tn ts in
          csubst sr (Flx_bsym.sr bsym) c 
            ~arg:(ce_atom "Error") ~args:[] 
            ~typs:[] ~argtyp:"Error" ~retyp:"Error" 
            ~gargs:ts 
            ~prec:"expr" 
            ~argshape:"Error" 
            ~argshapes:["Error"] 
            ~display:["Error"] 
            ~gargshapes:["Error"]
            ~name:(Flx_bsym.id bsym)
        end

      (* | BBDCL_fun (_,_,([s,(_,BTYP_void)],_),_,[BEXE_fun_return e]) -> *)
      | BBDCL_fun (_,_,([],_),_,[BEXE_fun_return (_,e)]) ->
        ge' e

      | BBDCL_cstruct _
      | BBDCL_struct _
      | BBDCL_fun _
      | BBDCL_external_fun _ ->
         syserr sr
         (
           "[gen_expr: name] Open function '" ^
           Flx_bsym.id bsym ^ "'<" ^ string_of_bid index ^
           "> in expression (closure required)"
         )
      | _ ->
        syserr sr
        (
          "[gen_expr: name] Cannot use this kind of name '"^
          Flx_bsym.id bsym ^ "' in expression"
        )
    end

  | BEXPR_closure (index,ts') ->
(*
    print_endline ("Generating closure of " ^ si index);
*)
    let bsym =
      try Flx_bsym_table.find bsym_table index with _ ->
        failwith ("[gen_expr(name)] Can't find index " ^ string_of_bid index)
    in
    (*
    Should not be needed now ..
    let ts = adjust_ts syms sym_table index ts' in
    *)
    let ts = map tsub ts' in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (props,_,_,_,_) ->
      let the_display =
        let d' =
          map begin fun (i,vslen) ->
            "ptr" ^ cpp_instance_name syms bsym_table i (list_prefix ts vslen)
          end (get_display_list bsym_table index)
        in
          if length d' > our_level
          then "this" :: tl d'
          else d'
      in
      let name = cpp_instance_name syms bsym_table index ts in
      if mem `Cfun props then ce_atom name
      else
        ce_atom (
        "(FLX_NEWP("^name^")" ^ Flx_gen_display.strd the_display props ^")"
        )

    | BBDCL_external_fun (_,_,_,_,_,_,`Callback _) ->
(*
      print_endline "Mapping closure of callback to C function pointer";
*)
      ce_atom (Flx_bsym.id bsym)

    | BBDCL_cstruct _
    | BBDCL_struct _
    | BBDCL_external_fun _ ->
      failwith ("[gen_expr: closure] Can't wrap primitive proc, fun, or " ^
        "struct '" ^ Flx_bsym.id bsym ^ "' yet")
    | _ ->
      failwith ("[gen_expr: closure] Cannot use this kind of name '" ^
      Flx_bsym.id bsym ^ "' in expression")
    end

  | BEXPR_ref (index,ts') ->
    let ts = map tsub ts' in
    let ref_type = tn t in
    (*
    let frame_ptr, var_ptr =
      match t with
      | BTYP_tuple [] -> "NULL","0"
      | _ ->

        let parent = match Flx_bsym_table.find bsym_table index with _,parent,sr,_ -> parent in
        if Some this = parent &&
        (
          let props = match entry with
            | BBDCL_fun (props,_,_,_,_) -> props
            | _ -> assert false
          in
          mem `Pure props && not (mem `Heap_closure props)
        )
        then
          "NULL","&"^get_var_ref syms bsym_table this index ts ^"-NULL"
        else
          get_var_frame syms bsym_table this index ts,
          "&" ^ get_var_ref syms bsym_table this index ts
    in
    let reference = ref_type ^
      "(" ^ frame_ptr ^ ", " ^ var_ptr ^ ")"
    in
    ce_atom reference
    *)

    ce_cast ref_type
    begin match t with
      | BTYP_tuple [] -> ce_atom "0"
      | _ ->
        let v = get_var_ref syms bsym_table this index ts in
        ce_prefix "&" (ce_atom v)
    end

  (* Hackery -- we allow a constructor with no
     arguments to be applied to a unit anyhow
  *)

  | BEXPR_variant (s,((_,t') as e)) -> failwith ("Temporarily egen not handling BEXPR_variant");
    print_endline ("Variant " ^ s);
    print_endline ("Type " ^ sbt bsym_table t);
    let
      arg_typename = tn t' and
      union_typename = tn t
    in
    let aval =
      "new (*PTF gcp, "^arg_typename^"_ptr_map,true) " ^
      arg_typename ^ "(" ^ ge_arg e ^ ")"
    in
    let ls = match t with
      | BTYP_variant ls -> ls
      | _ -> failwith "[egen] Woops variant doesn't have variant type"
    in
    let vidx = match list_assoc_index ls s with
      | Some i -> i
      | None -> failwith "[egen] Woops, variant field not in type"
    in
    print_endline ("Index " ^ si vidx);
    let uval = "::flx::rtl::_uctor_("^si vidx^"," ^ aval ^")"  in
    ce_atom uval

  | BEXPR_coerce ((srcx,srct) as srce,dstt) -> 
(*
print_endline ("Handling coercion in egen " ^ sbt bsym_table srct ^ " -> " ^ sbt bsym_table dstt);
*)
    let coerce_variant () =
      let vts =
        match dstt with
        | BTYP_variant ls -> ls
        | _ -> syserr sr "Coerce non-variant"
      in
      begin match srcx with
      | BEXPR_variant (s,argt) ->
        print_endline "Coerce known variant!";
        ge' (bexpr_variant t (s,argt))
      | _ ->
        let i =
          begin try
            Hashtbl.find syms.variant_map (srct,dstt)
          with Not_found ->
            let i = fresh_bid syms.counter in
            Hashtbl.add syms.variant_map (srct,dstt) i;
            i
        end
        in
        failwith "egen: can't handle variant conversions yet";
        ce_atom ("::flx::rtl::_uctor_(vmap_" ^ cid_of_bid i ^ "," ^ ge srce ^ ")")
      end
    in
    begin match dstt with
    | BTYP_variant _ -> coerce_variant ()
    | _ -> ce_atom ("reinterpret<"^tn dstt^">("^ge srce^")")
    end


  | BEXPR_compose _ -> failwith "Flx_egen:Can't handle closure of composition yet"

  | BEXPR_apply ((BEXPR_compose (f1, f2),_), e) ->
      failwith ("flx_egen: application of composition should have been reduced away")

  | BEXPR_apply
     (
       (BEXPR_case (v,t),t'),
       (a,t'')
     ) -> 
    if Flx_btype.islinear_type bsym_table t then begin
print_endline ("egen:BEXPR_apply BEXPR_case: index type = " ^ sbt bsym_table t );
(*
print_endline ("egen:BEXPR_apply BEXPR_case: index value = " ^ sbe bsym_table (e,t));
*)
      let sidx = Flx_ixgen.cal_symbolic_array_index bsym_table (e,t) in
(*
print_endline ("egen:BEXPR_apply BEXPR_case: Symbolic index = " ^ Flx_ixgen.print_index bsym_table sidx );
*)
      let cidx = Flx_ixgen.render_index bsym_table ge' array_sum_offset_table seq sidx in
(*
print_endline ("egen:BEXPR_apply BEXPR_case: rendered lineralised index .. C index = " ^ string_of_cexpr cidx);
*)
      cidx
    end
    else
(*
print_endline "Apply case ctor";
*)
       Flx_vgen.gen_make_nonconst_ctor ge' tn syms bsym_table t v t' (a,t'')
       (* t is the type of the sum,
          t' is the function type of the constructor,
          t'' is the type of the argument
       *)

  (* HACKY EXPERIMENT ALLOWING PRIMITIVE FUNCTIONS LIKE f: T -> T -> T = "..."
     i.e. with curried arguments, allowing call like f a b .. instead of tuple,
     ONLY works for expressions not procedure calls. ONLY works for 2 or 3 arguments.
     NO SUPPORT for closures! Do not use with tuple arguments as well as the
     whole tuple gets passed!
  *)
  | BEXPR_apply ((BEXPR_apply ( ((BEXPR_apply_prim (index, ts, arg1)),_),arg2),_),arg3) ->
    gen_apply_prim
      syms
      bsym_table
      this
      sr
      this_vs
      this_ts
      t
      index
      ts
      (bexpr_tuple (btyp_tuple [snd arg1; snd arg2; snd arg3]) [arg1; arg2; arg3])

  | BEXPR_apply ((BEXPR_apply_prim (index, ts, arg1),_) ,arg2) ->
    gen_apply_prim
      syms
      bsym_table
      this
      sr
      this_vs
      this_ts
      t
      index
      ts
      (bexpr_tuple (btyp_tuple [snd arg1; snd arg2]) [arg1; arg2])

  | BEXPR_apply_prim (index,ts,arg) ->
(*
print_endline "Apply prim";
*)
    gen_apply_prim
      syms
      bsym_table
      this
      sr
      this_vs
      this_ts
      t
      index
      ts
      arg

  | BEXPR_apply_struct (index,ts,a) ->
(*
print_endline "Apply struct";
*)
    let bsym =
      try Flx_bsym_table.find bsym_table index with _ ->
        failwith ("[gen_expr(apply instance)] Can't find index " ^
          string_of_bid index)
    in
    let ts = map tsub ts in
    begin match Flx_bsym.bbdcl bsym with
    | BBDCL_cstruct (vs,_,_) ->
      let name = tn (btyp_inst (index,ts)) in
      ce_atom ("reinterpret<"^ name ^">(" ^ ge a ^ ")")

    | BBDCL_struct (vs,cts) ->
      let name = tn (btyp_inst (index,ts)) in
      if length cts > 1 then
        (* argument must be an lvalue *)
        ce_atom ("reinterpret<"^ name ^">(" ^ ge a ^ ")")
      else if length cts = 0 then
        ce_atom (name ^ "()")
      else
        ce_atom (name ^ "(" ^ ge a ^ ")")

    | BBDCL_nonconst_ctor (vs,uidx,udt,cidx,ct,evs, etraint) ->
      (* due to some hackery .. the argument of a non-const
         ctor can STILL be a unit .. prolly cause the stupid
         compiler is checking for voids for these pests,
         but units for sums .. hmm .. inconsistent!
      *)
      let ts = map tsub ts in
      let ct = beta_reduce "flx_egen: nonconst ctor" syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts ct) in
      Flx_vgen.gen_make_nonconst_ctor ge' tn syms bsym_table udt cidx ct a 
    | _ -> assert false
    end

  | BEXPR_apply_direct (index,ts,a) ->
    let bsym = Flx_bsym_table.find bsym_table index in
    let ts = map tsub ts in
    let index', ts' = Flx_typeclass.fixup_typeclass_instance syms bsym_table index ts in
    if index <> index' then
      clierr sr ("[Flx_egen:apply_direct] Virtual call of " ^ string_of_bid index ^ " dispatches to " ^
        string_of_bid index')
    ;
    if index <> index' then
    begin
      let bsym =
        try Flx_bsym_table.find bsym_table index' with Not_found ->
          syserr sr ("MISSING INSTANCE BBDCL " ^ string_of_bid index')
      in
      match Flx_bsym.bbdcl bsym with
      | BBDCL_fun _ -> ge' (bexpr_apply_direct t (index',ts',a))
      | BBDCL_external_fun _ -> ge' (bexpr_apply_prim t (index',ts',a))
      | _ ->
          clierr2 sr (Flx_bsym.sr bsym) ("expected instance to be function " ^
            Flx_bsym.id bsym)
    end else

    let bsym =
      try Flx_bsym_table.find bsym_table index with _ ->
        failwith ("[gen_expr(apply instance)] Can't find index " ^
          string_of_bid index)
    in
    begin
    (*
    print_endline ("apply closure of "^ id );
    print_endline ("  .. argument is " ^ string_of_bound_expression sym_table a);
    *)
    match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (props,_,_,_,_) ->
      (*
      print_endline ("Generating closure[apply direct] of " ^ si index);
      *)
      let the_display =
        let d' =
          map begin fun (i,vslen)->
            "ptr" ^ cpp_instance_name syms bsym_table i (list_prefix ts vslen)
          end (get_display_list bsym_table index)
        in
          if length d' > our_level
          then "this" :: tl d'
          else d'
      in
      let name = cpp_instance_name syms bsym_table index ts in
      if mem `Cfun props
      then  (* this is probably wrong because it doesn't split arguments up *)
        ce_call (ce_atom name) [ce_atom (ge_arg a)]
      else
        ce_atom (
        "(FLX_NEWP("^name^")"^ Flx_gen_display.strd the_display props ^")"^
        "\n      ->apply(" ^ ge_arg a ^ ")"
        )

    | BBDCL_external_fun _ -> assert false
    (*
      ge' (BEXPR_apply_prim (index,ts,a),t)
    *)

    | _ ->
      failwith
      (
        "[gen_expr: apply_direct] Expected '" ^ Flx_bsym.id bsym ^ "' to be generic function instance, got:\n" ^
        string_of_bbdcl bsym_table (Flx_bsym.bbdcl bsym) index
      )
    end

  | BEXPR_apply_stack (index,ts,a) ->
    let bsym = Flx_bsym_table.find bsym_table index in
    let ts = map tsub ts in
    let index', ts' = Flx_typeclass.fixup_typeclass_instance syms bsym_table index ts in
    if index <> index' then
      clierr sr ("[Flx_egen: apply_stack] Virtual call of " ^ string_of_bid index ^ " dispatches to " ^
        string_of_bid index')
    ;
    if index <> index' then
    begin
      let bsym =
        try Flx_bsym_table.find bsym_table index' with Not_found ->
          syserr sr ("MISSING INSTANCE BBDCL " ^ string_of_bid index')
      in
      match Flx_bsym.bbdcl bsym with
      | BBDCL_fun _ -> ge' (bexpr_apply_direct t (index',ts',a))
      | BBDCL_external_fun _ -> ge' (bexpr_apply_prim t (index',ts',a))
      | _ ->
          clierr2 sr (Flx_bsym.sr bsym) ("expected instance to be function " ^
            Flx_bsym.id bsym)
    end else

    let bsym =
      try Flx_bsym_table.find bsym_table index with _ ->
        failwith ("[gen_expr(apply instance)] Can't find index " ^
          string_of_bid index)
    in
    begin
    match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (props,vs,(ps,traint),retyp,_) ->
      let display = get_display_list bsym_table index in
      let name = cpp_instance_name syms bsym_table index ts in
      (* C FUNCTION CALL *)
      if mem `Pure props && not (mem `Heap_closure props) then
      begin
        let s =
          assert (length display = 0);
          match ps with
          | [] -> ""
          | [{pindex=ix; ptyp=t}] ->
            if Hashtbl.mem syms.instances (ix,ts)
            then ge_arg a
            else ""

          | _ ->
            ge_carg ps ts vs a
        in
        let s =
          if mem `Requires_ptf props then
            if String.length s > 0 then "FLX_FPAR_PASS " ^ s
            else "FLX_FPAR_PASS_ONLY"
          else s
        in
          ce_atom (name ^ "(" ^ s ^ ")")
      end else
        let the_display =
          let d' =
            map (fun (i,vslen)-> "ptr"^ cpp_instance_name syms bsym_table i (list_prefix ts vslen))
            display
          in
            if length d' > our_level
            then "this" :: tl d'
            else d'
        in
        let s =
          name^ Flx_gen_display.strd the_display props
          ^
          "\n      .apply(" ^ ge_arg a ^ ")"
        in ce_atom s

    | _ ->
      failwith
      (
        "[gen_expr: apply_stack] Expected '" ^ Flx_bsym.id bsym ^ "' to be generic function instance, got:\n" ^
        string_of_bbdcl bsym_table (Flx_bsym.bbdcl bsym) index
      )
    end

  | BEXPR_apply ((BEXPR_closure (index,ts),_),a) ->
    print_endline "Compiler bug in flx_egen, application of closure found, should have been factored out!";
    assert false (* should have been factored out *)

  (* application of C function pointer, type
     f: a --> b
  *)
  (*
  | BEXPR_apply ( (_,BTYP_lvalue(BTYP_cfunction _)) as f,a)
  *)
  | BEXPR_apply ( (_,BTYP_cfunction (d,_)) as f,a) ->
(*
print_endline "Apply cfunction";
*)
    begin match d with
    | BTYP_tuple ts ->
      begin match a with
      | BEXPR_tuple xs,_ ->
        let s = String.concat ", " (List.map (fun x -> ge x) xs) in
        ce_atom ( (ge f) ^"(" ^ s ^ ")")
      | _ ->
       failwith "[flx_egen][tuple] can't split up arg to C function yet"
      end
    | BTYP_array (t,BTYP_unitsum n) ->
      let ts = 
       let rec aux ts n = if n = 0 then ts else aux (t::ts) (n-1) in
       aux [] n
      in
      begin match a with
      | BEXPR_tuple xs,_ ->
        let s = String.concat ", " (List.map (fun x -> ge x) xs) in
        ce_atom ( (ge f) ^"(" ^ s ^ ")")
      | _ ->
        failwith "[flx_egen][array] can't split up arg to C function yet"
      end

    | _ ->
      ce_atom ( (ge f) ^"(" ^ ge_arg a ^ ")")
    end

  (* General application*)
  | BEXPR_apply (f,a) ->
(*
print_endline "Apply general";
*)
    ce_atom (
    "("^(ge f) ^ ")->clone()\n      ->apply(" ^ ge_arg a ^ ")"
    )

  | BEXPR_record es ->
    let rcmp (s1,_) (s2,_) = compare s1 s2 in
    let es = sort rcmp es in
    let es = map snd es in
    let ctyp = tn t in
    ce_atom (
    ctyp ^ "(" ^
      fold_left
      (fun s e ->
        let x = ge_arg e in
        if String.length x = 0 then s else
        s ^
        (if String.length s > 0 then ", " else "") ^
        x
      )
      ""
      es
    ^
    ")"
    )

  | BEXPR_tuple es ->
    (* print_endline ("Construct tuple " ^ sbe bsym_table (e,t)); *)
    if islinear_type bsym_table t then begin
(*
      print_endline ("Construct tuple of linear type " ^ sbe bsym_table (e,t));
      print_endline ("type " ^ sbt bsym_table t);
*)
      let sidx = Flx_ixgen.cal_symbolic_array_index bsym_table (e,t) in
(*
print_endline ("egen:BEXPR_tuple: Symbolic index = " ^ Flx_ixgen.print_index bsym_table sidx );
*)
      let cidx = Flx_ixgen.render_index bsym_table ge' array_sum_offset_table seq sidx in
(*
print_endline ("egen:BEXPR_tuple: rendered lineralised index .. C index = " ^ string_of_cexpr cidx);
*)
      cidx 
    end
    else
    (* just apply the tuple type ctor to the arguments *)
    begin match t with
    | BTYP_array (t',BTYP_unitsum n) ->
(*
print_endline "Construct tuple, subkind array";
*)
      let t'' = btyp_tuple (map (fun _ -> t') (nlist n)) in
      let ctyp = raw_typename t'' in
      ce_atom (
        ctyp ^ "(" ^
        List.fold_left begin fun s e ->
          let x = ge_arg e in
(*
print_endline ("Construct tuple, subkind array, component x=" ^ x);
*)
          if String.length x = 0 then s else
          s ^
          (if String.length s > 0 then ", " else "") ^
          x
        end "" es
        ^
        ")"
      )

    | BTYP_tuple _ ->
(*
print_endline "Construct tuple, subkind tuple";
*)
      let ctyp = tn t in
      ce_atom (
        ctyp ^ "(" ^
        List.fold_left begin fun s e ->
          let x = ge_arg e in
(*
print_endline ("Construct tuple, subkind tuple, component x=" ^ x);
*)
          if String.length x = 0 then s else
          s ^
          (if String.length s > 0 then ", " else "") ^
          x
        end "" es
        ^
        ")"
      )
    | _ -> assert false
    end

(** Code generate for the BEXPR_apply_prim variant. *)
and gen_apply_prim
  syms
  bsym_table
  this
  sr
  this_vs
  this_ts
  t
  index
  ts
  ((arg,argt) as a)
=
  let gen_expr' = gen_expr' syms bsym_table this this_vs this_ts in
  let beta_reduce calltag vs ts t =
    beta_reduce calltag syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t)
  in
  let cpp_typename t = cpp_typename
    syms
    bsym_table
    (beta_reduce "flx_egen gen_apply_prim: cpp_typename" this_vs this_ts t)
  in
  let bsym =
    try Flx_bsym_table.find bsym_table index with Not_found ->
      failwith ("[gen_expr(apply instance)] Can't find index " ^
        string_of_bid index)
  in
  let id = Flx_bsym.id bsym in
  match Flx_bsym.bbdcl bsym with
  | BBDCL_external_fun (_,vs,_,retyp,_,prec,kind) ->
      if length vs <> length ts then
      failwith
      (
        "[get_expr:apply closure of fun] function " ^
        Flx_bsym.id bsym ^ "<" ^ string_of_bid index ^ ">" ^
        ", wrong number of args, expected vs = " ^
        si (length vs) ^
        ", got ts=" ^
        si (length ts)
      );
      begin match kind with
      | `Code CS.Identity -> gen_expr' sr a
      | `Code CS.Virtual ->
          print_endline ("Flx_egen[gen_apply_prim]: Warning: delayed virtual instantiation, external fun " ^ 
            Flx_bsym.id bsym^ "<"^string_of_bid index^ ">["^catmap "," (sbt bsym_table) ts^"]");
          let ts = List.map (beta_reduce "flx_egen: gen_apply_prim2" this_vs this_ts) ts in
          let index', ts' = Flx_typeclass.fixup_typeclass_instance
            syms
            bsym_table
            index
            ts
          in

          if index <> index' then begin
            clierr sr ("[Flx_egen: apply_prim] Virtual call of " ^ string_of_bid index ^
              " dispatches to " ^ string_of_bid index')
          end;

          if index = index' then begin
            let entries =
              try Hashtbl.find syms.virtual_to_instances index
              with Not_found -> []
            in

            clierr2 sr (Flx_bsym.sr bsym) ("Instantiate virtual function(2) " ^
              Flx_bsym.id bsym ^ "<" ^
              string_of_bid index ^ ">, no instance for ts="^
              catmap "," (sbt bsym_table) ts ^ "\n" ^
              "Instances are " ^ 
              catmap "\n" 
                (fun (bvs, ret, args, ix) -> 
                  Flx_print.string_of_bvs bvs ^ 
                 (catmap "*" (sbt bsym_table) args) ^ "->" ^ sbt bsym_table ret
                ) 
                entries)
          end;

          let bsym =
            try Flx_bsym_table.find bsym_table index' with Not_found ->
              syserr sr ("MISSING INSTANCE BBDCL " ^ string_of_bid index')
          in
          begin match Flx_bsym.bbdcl bsym with
          | BBDCL_fun _ ->
              gen_expr' sr (bexpr_apply_direct t (index',ts',a))
          | BBDCL_external_fun _ ->
              gen_expr' sr (bexpr_apply_prim t (index',ts',a))
          | _ ->
              clierr2 sr (Flx_bsym.sr bsym)
                ("expected instance to be function " ^ Flx_bsym.id bsym)
          end
      | `Code (CS.Str s) -> ce_expr prec s
      | `Code (CS.Str_template s) ->
          gen_prim_call
            syms
            bsym_table
            (beta_reduce "flx_egen: Code" this_vs this_ts)
            gen_expr'
            s
            (List.map (beta_reduce "flx_egen: Code2 " this_vs this_ts) ts)
            (arg, beta_reduce "flx_egen: code2" this_vs this_ts argt)
            (beta_reduce "flx_egen: code4" vs ts retyp)
            sr
            (Flx_bsym.sr bsym)
            prec
            id
      | `Callback (_,_) ->
          assert (retyp <> btyp_void ());
          gen_prim_call
            syms
            bsym_table
            (beta_reduce "flx_egen: callback" this_vs this_ts)
            gen_expr'
            (Flx_bsym.id bsym ^ "($a)")
            (List.map (beta_reduce "flx_egen: callback2" this_vs this_ts) ts)
            (arg, beta_reduce "flx_egen: callback3" this_vs this_ts argt)
            (beta_reduce "flx_egen: callback4" vs ts retyp)
            sr
            (Flx_bsym.sr bsym)
            "atom"
            id
      end

  (* but can't be a Felix function *)
  | _ ->
      failwith
      (
        "[gen_expr: apply prim] Expected '" ^ Flx_bsym.id bsym ^
        "' to be primitive function instance, got:\n" ^
        string_of_bbdcl bsym_table (Flx_bsym.bbdcl bsym) index
      )

and gen_expr syms bsym_table this vs ts sr e : string =
  let e = Flx_bexpr.reduce e in
  let s =
    try gen_expr' syms bsym_table this vs ts sr e
    with Unknown_prec p -> clierr sr
    ("[gen_expr] Unknown precedence name '"^p^"' in " ^ sbe bsym_table e)
  in
  string_of_cexpr s



