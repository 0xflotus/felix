(* gratuitous change *)
open Flx_types
open Flx_btype
open Flx_bexpr
open Flx_set
open Flx_mtypes2
open Flx_print
open Flx_maps
open Flx_util
open Flx_list
open Flx_exceptions

let unit_t = btyp_tuple []

let rec dual t =
  match Flx_btype.map ~ft:dual t with
  | BTYP_sum ls ->
    begin match ls with
    | [t] -> t
    | ls -> btyp_tuple ls
    end

  | BTYP_tuple ls ->
    begin match ls with
    | [] -> btyp_void
    | [t] -> t
    | ls -> btyp_sum ls
    end

  | BTYP_function (a,b) -> btyp_function (b,a)
  | BTYP_cfunction (a,b) -> btyp_cfunction (b,a)
  | BTYP_array (a,b) -> btyp_array (b,a)

  | BTYP_pointer t -> btyp_pointer (dual t)
  | BTYP_void -> unit_t
  | BTYP_unitsum k ->
    let rec aux ds k = if k = 0 then ds else aux (unit_t::ds) (k-1) in
    btyp_tuple (aux [] k)

  | BTYP_type_set ts -> btyp_intersect (List.map dual ts)
  | BTYP_intersect ts -> btyp_type_set (List.map dual ts)
  | BTYP_record ts -> btyp_variant ts
  | t -> t

(* top down check for fix point not under sum or pointer *)
let rec check_recursion t = match t with
   | BTYP_pointer _
   | BTYP_sum _
   | BTYP_function _
   | BTYP_cfunction _
     -> ()

   | BTYP_fix i
     -> raise Bad_recursion

   | x -> Flx_btype.iter ~ft:check_recursion x

let var_subst t (i, j) =
  let rec ft t =
    match t with
    | BTYP_type_var (k,t) when i = k -> btyp_type_var (j,t)
    | t -> Flx_btype.map ~ft t
  in
  ft t

let vars_subst ls t = List.fold_left var_subst t ls

let rec alpha counter t =
  match t with
  | BTYP_type_function (ps,r,b) ->
      let remap_list = List.map (fun (i,_) -> i, fresh_bid counter) ps in
      let remap i = List.assoc i remap_list in
      let cvt t = alpha counter (vars_subst remap_list t) in
      let ps = List.map (fun (i,t) -> remap i,t) ps in
      btyp_type_function (ps, cvt r, cvt b)
  | t -> Flx_btype.map ~ft:(alpha counter) t

let term_subst counter t1 i t2 =
  let rec s t =
  match t with
  | BTYP_type_var (k,_) when k = i -> t2

  | BTYP_type_match (tt, pts) ->
    let tt = s tt in
    let pts =
      List.map begin fun ((bpat, x) as case) ->
       if BidSet.mem i bpat.pattern_vars then case else
       let asgs = List.map (fun (i,t) -> i, s t) bpat.assignments in
       { bpat with pattern=s bpat.pattern; assignments=asgs }, s x
      end pts
    in
    btyp_type_match (tt,pts)

  | t -> Flx_btype.map ~ft:s t
  in s t1

let list_subst counter x t =
  let t = alpha counter t in
  List.fold_left (fun t1 (i,t2) ->
    term_subst counter t1 i (alpha counter t2))
  t
  x

let varmap0_subst varmap t =
  let rec ft t =
    match Flx_btype.map ~ft t with
    | BTYP_type_var (i,_) as x ->
        if Hashtbl.mem varmap i
        then Hashtbl.find varmap i
        else x
    | x -> x
  in
  ft t

let varmap_subst varmap t =
  let rec ft t =
    match Flx_btype.map ~ft t with
    | BTYP_type_var (i,_) as x ->
        if Hashtbl.mem varmap i
        then Hashtbl.find varmap i
        else x
    | BTYP_type_function (p,r,b) ->
        let
          p = List.map (fun (name,kind) -> (name, ft kind)) p and
          r = ft r and
          b = ft b
        in
        btyp_type_function (p,r,b)
    | x -> x
  in
  ft t

(* the type arguments are matched up with the type
  variables in order so that
  vs_i -> ts_i
  where vs_t might be (fred,var j)
*)
let mk_varmap vs ts =
  if List.length ts <> List.length vs
  then
    failwith
    (
      "[mk_varmap] wrong number of type args, expected vs=" ^
      si (List.length vs) ^
      ", got ts=" ^
      si (List.length ts) ^
      "\nvs= " ^ catmap "," (fun (s,i) -> s ^ "<" ^ string_of_bid i ^ ">") vs
    )
  ;
  let varmap = Hashtbl.create 97 in
  List.iter2
  (fun (_, varidx) typ -> Hashtbl.add varmap varidx typ)
  vs ts
  ;
  varmap

let tsubst vs ts t =
  varmap_subst (mk_varmap vs ts) t

(* returns the most general unifier (mgu)
  of a set of type equations as a list
  of variable assignments i -> t
  or raises Not_found if there is no solution

  HOW IT WORKS:

  We start with some set of type equations
  t1 = t2
  t3 = t4  (1)
  ...

  in which the LHS and RHS are general terms that
  may contain type variables.

  We want to say whether the equations are consistent,
  and if so, to return a solution of the form
  of a set of equations:

  v1 = u1
  v2 = u2   (2)

  where v1 .. vn are type variable
  which do not occur in any of the
  terms u1 .. un

  Such a set is a solution if by replacing v1 with u1,
  v2 with u2 .. vn with un,
  everywhere they occur in t1, t2 .... tn,
  the original equations are reduced to
  equations terms which are structurally equal

  The technique is to pick one equation,
  and match up the outermost structure,
  making new equations out of the pieces in the middle,
  or failing if the outer structure does not match.

  We discard the original equation,
  add the new equations to the set,
  and then for any variable assignments of form (2)
  found, we eliminate that variable in the
  all the other equations by substitution.


  At the end we are guarrateed to either have found
  the equations have no solution, or computed one,
  although it may be that the terms u1 .. u2 ..
  contain some type variables.

  There is a caveat though: we may obtain
  an equation

    v = t

  where v occurs in t, that is, a recursive equation.
  If that happens, we eliminate the occurences
  of v in t before replacement in other equations:
  we do this by replacing the RHS occurences of
  v with a fixpoint operator.

*)

let var_i_occurs i t =
  let rec aux t:unit = match t with
    | BTYP_type_var (j,_) when i = j -> raise Not_found
    | _ -> Flx_btype.iter ~ft:aux t
 in
   try
     aux t;
     false
   with Not_found -> true

let rec vars_in t =
  let vs = ref BidSet.empty in
  let add_var i = vs := BidSet.add i !vs in
  let rec aux t = match t with
    | BTYP_type_var (i,_) -> add_var i
    | _ -> Flx_btype.iter ~ft:aux t
  in aux t; !vs

let fix i t =
  let rec aux n t =
    let aux t = aux (n - 1) t in
    match t with
    | BTYP_type_var (k,_) -> if k = i then btyp_fix n else t
    | BTYP_inst (k,ts) -> btyp_inst (k, List.map aux ts)
    | BTYP_tuple ts -> btyp_tuple (List.map aux ts)
    | BTYP_sum ts -> btyp_sum (List.map aux ts)
    | BTYP_intersect ts -> btyp_intersect (List.map aux ts)
    | BTYP_type_set ts -> btyp_type_set (List.map aux ts)
    | BTYP_function (a,b) -> btyp_function (aux a, aux b)
    | BTYP_cfunction (a,b) -> btyp_cfunction (aux a, aux b)
    | BTYP_pointer a -> btyp_pointer (aux a)
    | BTYP_array (a,b) -> btyp_array (aux a, aux b)

    | BTYP_record ts ->
       btyp_record (List.map (fun (s,t) -> s, aux t) ts)

    | BTYP_variant ts ->
       btyp_variant (List.map (fun (s,t) -> s, aux t) ts)

    | BTYP_unitsum _
    | BTYP_void
    | BTYP_fix _
    | BTYP_type_apply _
    | BTYP_type_function _
    | BTYP_type _
    | BTYP_type_tuple _
    | BTYP_type_match _
    | BTYP_type_set_union _ -> t
    | BTYP_type_set_intersection _ -> t
  in
    aux 0 t

let var_list_occurs ls t =
  let yes = ref false in
  List.iter (fun i -> yes := !yes || var_i_occurs i t) ls;
  !yes

(* NOTE: this algorithm unifies EQUATIONS
  not inequations, therefore it doesn't
  handle any subtyping
*)

(* NOTE: at the moment,
  unification doesn't care about type variable
  meta types: we should probably require them
  to be the same for an assignment or fail
  the unification .. however that requires
  comparing the metatypes for equality, and to that
  that right requires unification .. :)
*)

let rec unification counter eqns dvars =
  (*
  print_endline ( "Dvars = { " ^ catmap ", " si (BidSet.elements dvars) ^ "}");
  *)
  let eqns = ref eqns in
  let mgu = ref [] in
  let rec loop () : unit =
    match !eqns with
    | [] -> ()
    | h :: t ->
      eqns := t;
      let s = ref None in
      begin match h with
      | (BTYP_type_var (i,mi) as ti), (BTYP_type_var (j,mj) as tj)->
        (*
        print_endline ("Equated variables " ^ si i ^ " <-> " ^ si j);
        *)

        (* meta type have to agree *)
        if mi <> mj then raise Not_found;

        if i <> j then
          if BidSet.mem i dvars then
            s := Some (i,tj)
          else if BidSet.mem j dvars then
            s := Some (j,ti)
          else raise Not_found
      | BTYP_type_var (i,_), t
      | t,BTYP_type_var (i,_) ->
        (*
        print_endline ("variable assignment " ^ si i ^ " -> " ^ sbt sym_table t);
        *)

        (* WE SHOULD CHECK THAT t has the right meta type .. but
        the metatype routine isn't defined yet ..
        *)
        if not (BidSet.mem i dvars) then raise Not_found;
        if var_i_occurs i t
        then begin
          (*
          print_endline
          (
            "recursion in unification, terms: " ^
            match h with (a,b) ->
            sbt sym_table a ^ " = " ^ sbt sym_table b
          );
          *)
          s := Some (i, fix i t)
        end else begin
          (*
          print_endline "Adding substitution";
          *)
          s := Some (i,t)
        end

      | BTYP_intersect ts,t
      | t,BTYP_intersect ts ->
        List.iter (function t' -> eqns := (t,t') :: !eqns) ts

      | BTYP_pointer t1, BTYP_pointer t2 ->
        eqns := (t1,t2) :: !eqns

      | BTYP_unitsum i, BTYP_unitsum j when i = j -> ()

      | BTYP_unitsum k, BTYP_sum ls
      | BTYP_sum ls, BTYP_unitsum k when List.length ls = k ->
        List.iter
        (function
          | BTYP_type_var _ as v ->
             eqns := (v,unit_t) :: !eqns
          | _ -> raise Not_found
        )
        ls

      | BTYP_array (t11, t12), BTYP_array (t21, t22)
      | BTYP_function (t11, t12), BTYP_function (t21, t22)
      | BTYP_cfunction (t11, t12), BTYP_cfunction (t21, t22) ->
        eqns := (t11,t21) :: (t12,t22) :: !eqns

      | BTYP_record [],BTYP_tuple []
      | BTYP_tuple [],BTYP_record [] -> ()

      | BTYP_record t1,BTYP_record t2 ->
        if List.length t1 = List.length t2
        then begin
          let rcmp (s1,_) (s2,_) = compare s1 s2 in
          let t1 = List.sort rcmp t1 in
          let t2 = List.sort rcmp t2 in
          if (List.map fst t1) <> (List.map fst t2) then raise Not_found;
          let rec merge e a b = match a,b with
          | [],[] -> e
          | ah :: at, bh :: bt -> merge ((ah,bh) :: e) at bt
          | _ -> assert false
          in
            eqns := merge !eqns (List.map snd t1) (List.map snd t2);
            s := None
        end
        else raise Not_found

      | BTYP_variant [],BTYP_void
      | BTYP_void,BTYP_variant [] -> ()

      | BTYP_variant t1,BTYP_variant t2 ->
        if List.length t1 = List.length t2
        then begin
          let rcmp (s1,_) (s2,_) = compare s1 s2 in
          let t1 = List.sort rcmp t1 in
          let t2 = List.sort rcmp t2 in
          if (List.map fst t1) <> (List.map fst t2) then raise Not_found;
          let rec merge e a b = match a,b with
          | [],[] -> e
          | ah :: at, bh :: bt -> merge ((ah,bh) :: e) at bt
          | _ -> assert false
          in
            eqns := merge !eqns (List.map snd t1) (List.map snd t2);
            s := None
        end
        else raise Not_found

      | BTYP_type i,BTYP_type j when i = j -> ()
      | BTYP_void,BTYP_void -> ()

      | BTYP_inst (i1,ts1),BTYP_inst (i2,ts2) ->
        if i1 <> i2 then raise Not_found
        else if List.length ts1 <> List.length ts2 then raise Not_found
        else
        begin
          let rec merge e a b = match a,b with
          | [],[] -> e
          | ah :: at, bh :: bt -> merge ((ah,bh) :: e) at bt
          | _ -> assert false
          in
            eqns := merge !eqns ts1 ts2;
            s := None
        end

      | BTYP_fix i,BTYP_fix j ->
        if i <> j then raise Not_found

      (* array/tuple sidedness must be preserved in
         case of lvalue decay, which only affects the
         RHS term [that is, argument lvalue[t] matches
         parameter t, but not the other way around]
      *)
      | BTYP_tuple ls, BTYP_array (ta,BTYP_unitsum n)
        when n = List.length ls ->
        List.iter (fun t -> eqns := (t,ta) :: !eqns) ls

      | BTYP_array (ta,BTYP_unitsum n), BTYP_tuple ls
        when n = List.length ls ->
        List.iter (fun t -> eqns := (ta,t) :: !eqns) ls

      (* type tuple is handled same as a tuple type .. not
        really sure this is right. Certainly, the corresponding
        terms in both must unify, however possibly we should
        return distinct MGU for each case for the type tuple,
        possibly with distinct bindings for the same variable..
      *)

      | (BTYP_type_tuple ls1, BTYP_type_tuple ls2)
      | (BTYP_tuple ls1, BTYP_tuple ls2)
      | (BTYP_sum ls1, BTYP_sum ls2)
        when List.length ls1 = List.length ls2 ->
        begin
          let rec merge e a b = match a,b with
          | [],[] -> e
          | ah :: at, bh :: bt -> merge ((ah,bh) :: e) at bt
          | _ -> assert false
          in
            eqns := merge !eqns ls1 ls2;
            s := None
        end

      (* structural, not functional, equality of lambdas by alpha equivalence *)
      | BTYP_type_function (p1,r1,b1), BTYP_type_function (p2,r2,b2)
        when List.length p1 = List.length p2 ->
        let vs = List.map2 (fun (i1,_) (i2,t) -> i1,btyp_type_var (i2,t))  p1 p2 in
        let b1 = list_subst counter vs b1 in
        eqns := (b1, b2):: !eqns;
        s := None

      | x,y ->
        (*
        print_endline ("Terms do not match: " ^ sbt sym_table x ^ " <-> " ^ sbt sym_table y);
        *)
        raise Not_found
      end
      ;
      begin match !s with
      | None -> ()
      | Some (i,t) ->
        (*
        print_endline ("Substituting " ^ si i ^ " -> " ^ sbt sym_table t);
        *)
        eqns :=
          List.map
          (fun (a,b) ->
            term_subst counter a i t,
            term_subst counter b i t
          )
          !eqns
        ;
        assert(not (List.mem_assoc i !mgu));
        mgu :=
          (i,t) ::
          (List.map
            (fun (j,t') -> j,term_subst counter t' i t)
            !mgu
          )
      end
      ;
      loop ()
    in
      loop ();
      !mgu

let find_vars_eqns eqns =
  let lhs_vars = ref BidSet.empty in
  let rhs_vars = ref BidSet.empty in
  List.iter (fun (l,r) ->
    lhs_vars := BidSet.union !lhs_vars (vars_in l);
    rhs_vars := BidSet.union !rhs_vars (vars_in r)
  )
  eqns
  ;
  !lhs_vars,!rhs_vars

let maybe_unification counter eqns =
  let l,r = find_vars_eqns eqns in
  let dvars = BidSet.union l r in
  try Some (unification counter eqns dvars)
  with Not_found -> None

let maybe_matches counter eqns =
  let l,r = find_vars_eqns eqns in
  let dvars = BidSet.union l r in
  try Some (unification counter eqns dvars)
  with Not_found -> None

let maybe_specialisation counter eqns =
  let l,_ = find_vars_eqns eqns in
  try Some (unification counter eqns l)
  with Not_found -> None

let unifies counter t1 t2 =
  let eqns = [t1,t2] in
  match maybe_unification counter eqns with
  | None -> false
  | Some _ -> true

let ge counter a b =
  (*
  print_endline ("Compare terms " ^ sbt sym_table a ^ " >? " ^ sbt sym_table b);
  *)
  match maybe_specialisation counter [a,b] with
  | None -> false
  | Some mgu ->
    (*
    print_endline ("MGU from specialisation = ");
    List.iter (fun (i, t) -> print_endline (si i ^ " --> " ^ sbt sym_table t)) mgu;
    print_endline "";
    *)
    true

let compare_sigs counter a b =
  match ge counter a b, ge counter b a with
  | true, true -> `Equal
  | false, false -> `Incomparable
  | true, false -> `Greater
  | false, true -> `Less

let rec memq trail (a,b) = match trail with
  | [] -> false
  | (i,j)::t -> i == a && j == b || memq t (a,b)

let rec type_eq' counter ltrail ldepth rtrail rdepth trail t1 t2 =
  (* print_endline (sbt sym_table t1 ^ " =? " ^ sbt sym_table t2); *)
  if memq trail (t1,t2) then true
  else let te a b = type_eq' counter
    ((ldepth,t1)::ltrail) (ldepth+1)
    ((rdepth,t2)::rtrail) (rdepth+1)
    ((t1,t2)::trail)
    a b
  in
  (*
  let assoc i ls =
    try List.assoc i ls
    with Not_found -> raise Not_found
      (*
      print_endline (
      "trail failure, index=" ^ si i ^ ", trail="
      ^ catmap "," (fun (k,t) -> si k ^ "->" ^ sbt sym_table t) ls
      );
      failwith "Trail failure"
      *)
  in
  *)
  match t1,t2 with
  | BTYP_inst (i1,ts1),BTYP_inst (i2,ts2) ->
    i1 = i2 &&
    List.length ts1 = List.length ts2 &&
    List.fold_left2
    (fun tr a b -> tr && te a b)
    true ts1 ts2

  | BTYP_unitsum i,BTYP_unitsum j -> i = j

  | BTYP_sum ts1, BTYP_sum ts2
  | BTYP_type_tuple ts1,BTYP_type_tuple ts2
  | BTYP_tuple ts1,BTYP_tuple ts2 ->
    let result =
    if List.length ts1 = List.length ts2
    then
      List.fold_left2
      (fun tr a b -> tr && te a b)
      true ts1 ts2
    else false
    in
    (*
    print_endline ("Tuple/sum compared " ^ (if result then "TRUE" else "FALSE"));
    if List.length ts1 = List.length ts2 then
    print_endline ("Args = " ^ catmap "\n  " (fun (t1,t2) ->
      "lhs=" ^sbt sym_table t1 ^" vs rhs=" ^ sbt sym_table t2)
     (combine ts1 ts2))
    else print_endline ("unequal lengths");
    *)
    result

  | BTYP_record [],BTYP_tuple []
  | BTYP_tuple [],BTYP_record [] -> true

  | BTYP_record t1,BTYP_record t2 ->
    if List.length t1 = List.length t2
    then begin
      let rcmp (s1,_) (s2,_) = compare s1 s2 in
      let t1 = List.sort rcmp t1 in
      let t2 = List.sort rcmp t2 in
      List.map fst t1 = List.map fst t2 &&
      List.fold_left2
      (fun tr a b -> tr && te a b)
      true (List.map snd t1) (List.map snd t2)
    end else false

  | BTYP_variant [],BTYP_tuple []
  | BTYP_tuple [],BTYP_variant [] -> true

  | BTYP_variant t1,BTYP_variant t2 ->
    if List.length t1 = List.length t2
    then begin
      let rcmp (s1,_) (s2,_) = compare s1 s2 in
      let t1 = List.sort rcmp t1 in
      let t2 = List.sort rcmp t2 in
      List.map fst t1 = List.map fst t2 &&
      List.fold_left2
      (fun tr a b -> tr && te a b)
      true (List.map snd t1) (List.map snd t2)
    end else false


  | BTYP_array (s1,d1),BTYP_array (s2,d2)
  | BTYP_function (s1,d1),BTYP_function (s2,d2)
  | BTYP_cfunction (s1,d1),BTYP_cfunction (s2,d2)
  | BTYP_type_apply(s1,d1),BTYP_type_apply(s2,d2)
    -> te s1 s2 && te d1 d2

  (* order is important for lvalues .. *)
  | BTYP_array (ta,BTYP_unitsum n),BTYP_tuple ts
    when List.length ts = n ->
    List.fold_left (fun tr t -> tr && te ta t) true ts


  | BTYP_tuple ts,BTYP_array (ta,BTYP_unitsum n)
    when List.length ts = n ->
    List.fold_left (fun tr t -> tr && te t ta) true ts

  | BTYP_pointer p1,BTYP_pointer p2
    -> te p1 p2

  | BTYP_void,BTYP_void
    -> true

  | BTYP_type_var (i,_), BTYP_type_var (j,_) ->
    let result = i = j in
    (*
    print_endline ("Type variables compared " ^ (if result then "TRUE" else "FALSE"));
    *)
    result


  | BTYP_fix i,BTYP_fix j ->
    (*
    print_endline ("Check fixpoint " ^ si i ^ " vs " ^ si j);
    *)
    if i = j then true else (* hack ..? *)
    begin
      (*
      print_endline "Matching fixpoints";
      *)
      try
      let a = List.assoc (ldepth+i) ltrail in
      let b = List.assoc (rdepth+j) rtrail in
      type_eq' counter ltrail ldepth rtrail rdepth trail a b
      with Not_found -> false
    end

  | BTYP_fix i,t ->
    (*
    print_endline "LHS fixpoint";
    *)
    begin try
    let a = List.assoc (ldepth+i) ltrail in
    type_eq' counter ltrail ldepth rtrail rdepth trail a t
    with Not_found -> false
    end

  | t,BTYP_fix j ->
    (*
    print_endline "RHS fixpoint";
    *)
    begin try
    let b = List.assoc (rdepth+j) rtrail in
    type_eq' counter ltrail ldepth rtrail rdepth trail t b
    with Not_found -> false
    end

  | BTYP_type_function (p1,r1,b1), BTYP_type_function (p2,r2,b2) ->
    List.length p1 = List.length p2 &&
    let vs = List.map2 (fun (i1,_) (i2,t) -> i1,btyp_type_var (i2,t))  p1 p2 in
    (*
    print_endline "Comparing type functions";
    print_endline ("b1 =          " ^ sbt sym_table b1);
    *)
    let b1 = list_subst counter vs b1 in
    (*
    print_endline ("Adjusted b1 = " ^ sbt sym_table b1);
    print_endline ("b2 =          " ^ sbt sym_table b2);
    *)
    let result = te b1 b2 in
    (*
    print_endline ("Compared = " ^ (if result then "TRUE" else "FALSE"));
    *)
    result

  | l,r ->
    (*
    print_endline ("WOOOPS .. dunno.." ^ sbt sym_table l ^" vs " ^ sbt sym_table r);
    *)
    false

let type_eq counter t1 t2 = (* print_endline "TYPE EQ";  *)
  type_eq' counter [] 0 [] 0 [] t1 t2

let type_match counter t1 t2 = (* print_endline "TYPE MATCH"; *)
  type_eq' counter [] 0 [] 0 [] t1 t2

(* NOTE: only works on explicit fixpoint operators,
  i.e. it won't work on typedefs: no name lookup,
  these should be removed first ..
  another view: only works on non-generative types.
*)

let unfold t =
  let rec aux depth t' =
  let uf t = aux (depth+1) t in
  match t' with
  | BTYP_sum ls -> btyp_sum (List.map uf ls)
  | BTYP_tuple ls -> btyp_tuple (List.map uf ls)
  | BTYP_record ls -> btyp_record (List.map (fun (s,t) -> s,uf t) ls)
  | BTYP_variant ls -> btyp_variant (List.map (fun (s,t) -> s,uf t) ls)
  | BTYP_array (a,b) -> btyp_array (uf a, uf b)
  | BTYP_function (a,b) -> btyp_function (uf a, uf b)
  | BTYP_cfunction (a,b) -> btyp_cfunction (uf a, uf b)
  | BTYP_pointer a -> btyp_pointer (uf a)
  | BTYP_fix i when (-i) = depth -> t
  | BTYP_fix i when (-i) > depth ->
    failwith ("[unfold] Fix point outside term, depth="^string_of_int i)

  | BTYP_type_apply (a,b) -> btyp_type_apply(uf a, uf b)
  | BTYP_inst (i,ts) -> btyp_inst (i,List.map uf ts)
  | BTYP_type_function (p,r,b) ->
      btyp_type_function (p,r,uf b)

  | BTYP_type_match (a,tts) ->
      let a = uf a in
      (* don't unfold recursions in patterns yet because we don't know what they
       * mean *)
      let tts = List.map (fun (p,x) -> p, uf x) tts in
      btyp_type_match (a,tts)

  | _ -> t'
  in aux 0 t

exception Found of Flx_btype.t

(* this undoes an unfold: it won't minimise an arbitrary type *)
let fold counter t =
  let rec aux trail depth t' =
    let ax t = aux ((depth,t')::trail) (depth+1) t in
    match t' with
    | BTYP_intersect ls
    | BTYP_sum ls
    | BTYP_inst (_,ls)
    | BTYP_tuple ls -> List.iter ax ls
    | BTYP_record ls -> List.iter (fun (s,t) -> ax t) ls
    | BTYP_variant ls -> List.iter (fun (s,t) -> ax t) ls

    | BTYP_array (a,b)
    | BTYP_function (a,b) -> ax a; ax b
    | BTYP_cfunction (a,b) -> ax a; ax b

    | BTYP_pointer a -> ax a

    | BTYP_void
    | BTYP_unitsum _
    | BTYP_type_var _
    | BTYP_fix 0 -> ()

    | BTYP_fix i ->
      let k = depth + i in
      begin try
        let t'' = List.assoc k trail in
        if type_eq counter t'' t then raise (Found t'')
      with Not_found -> ()
      end

    | BTYP_type_apply (a,b) -> ax a; ax b

    | BTYP_type_set_intersection _
    | BTYP_type_set_union _
    | BTYP_type_set _
    | BTYP_type_function _
    | BTYP_type _
    | BTYP_type_tuple _
    | BTYP_type_match _ -> () (* assume fixpoint can't span these boundaries *)
      (* failwith ("[fold] unexpected metatype " ^ sbt sym_table t') *)
  in
    try aux [] 0 t; t
    with Found t -> t

(* produces a unique minimal representation of a type
by folding at every node *)

let minimise counter t =
  fold counter (Flx_btype.map ~ft:(fold counter) t)

let var_occurs t =
  let rec aux' excl t = let aux t = aux' excl t in
    match t with
    | BTYP_intersect ls
    | BTYP_type_set ls
    | BTYP_type_set_intersection ls
    | BTYP_type_set_union ls
    | BTYP_sum ls
    | BTYP_inst (_,ls)
    | BTYP_tuple ls -> List.iter aux ls
    | BTYP_record ls -> List.iter (fun (s,t) -> aux t) ls
    | BTYP_variant ls -> List.iter (fun (s,t) -> aux t) ls

    | BTYP_array (a,b)
    | BTYP_function (a,b) -> aux a; aux b
    | BTYP_cfunction (a,b) -> aux a; aux b

    | BTYP_pointer a  -> aux a

    | BTYP_unitsum _
    | BTYP_void
    | BTYP_fix _ -> ()

    | BTYP_type_var (k,_) -> if not (List.mem k excl) then raise Not_found
    | BTYP_type_function (p,r,b) ->
      aux' (List.map fst p @ excl) b

    | _ -> failwith "[var_occurs] unexpected metatype"

 in try aux' [] t; false with Not_found -> true

let ident x = x

(* not really right! Need to map the types as well,
  since we're instantiating a polymorphic term with
  a more specialised one

  Also won't substitute into LHS of things like direct_apply.
*)
let expr_term_subst e1 i e2 =
  let rec s e =
    match Flx_bexpr.map ~fe:s e with
    | BEXPR_name (j,_),_ when i = j -> e2
    | e -> e
  in s e1

let rec expr_unification counter
  eqns
  tdvars
  edvars
=
  (*
  print_endline ( "Tdvars = { " ^ catmap ", " si (BidSet.elements tdvars) ^ "}");
  print_endline ( "Edvars = { " ^ catmap ", " si (BidSet.elements edvars) ^ "}");
  *)
  let teqns = ref [] in
  let eqns = ref eqns in
  let mgu = ref [] in
  let rec loop () : unit =
    match !eqns with
    | [] -> ()
    | h :: t ->
      eqns := t;
      let s = ref None in
      let (lhse,lhst),(rhse,rhst) = h in
      teqns := (lhst,rhst) :: !teqns;

      (* WE COULD UNIFY TYPES HERE -- but there is no need!
         if the terms unify, the types MUST
         We DO need to unify the types -- but only after
         we've found matching terms.

         Note: the types in the ts lists DO have to be
         unified! It's only the types OF terms that
         don't require processing .. since they're just
         convenience caches of the term type, which can
         be computed directly from the term.
      *)
      begin match (lhse,rhse) with
      | (BEXPR_name (i,[]) as ei), (BEXPR_name (j,[]) as ej) ->
        (*
        print_endline ("Equated variables " ^ si i ^ " <-> " ^ si j);
        *)

        if i <> j then
          if BidSet.mem i edvars then
            s := Some (i,(ej,rhst))
          else if BidSet.mem j edvars then
            s := Some (j,(ei,lhst))
          else raise Not_found

      | BEXPR_name (i,_),x ->
        if not (BidSet.mem i edvars) then raise Not_found;
        s := Some (i,(x,rhst))

      | x, BEXPR_name (i,_) ->
        if not (BidSet.mem i edvars) then raise Not_found;
        s := Some (i,(x,lhst))

      | BEXPR_apply (f1,e1), BEXPR_apply (f2,e2) ->
        (*
        print_endline "matched applications";
        *)
        eqns := (f1,f2) :: (e1,e2) :: !eqns

      | BEXPR_closure (i,ts1), BEXPR_closure (j,ts2) when i = j -> ()

      | BEXPR_apply_prim _, _
      | BEXPR_apply_direct _, _
      | BEXPR_apply_stack _, _
      | _, BEXPR_apply_prim _
      | _, BEXPR_apply_direct _
      | _, BEXPR_apply_stack _
         -> assert false

      (*
      | BEXPR_apply_prim (i,ts1,e1),BEXPR_apply_prim(j,ts2,e2)
      | BEXPR_apply ( (BEXPR_closure (i,ts1),_), e1),BEXPR_apply_prim(j,ts2,e2)
      | BEXPR_apply_prim (i,ts1,e1),BEXPR_apply( (BEXPR_closure(j,ts2),_),e2)

      | BEXPR_apply_direct (i,ts1,e1),BEXPR_apply_direct(j,ts2,e2)
      | BEXPR_apply ( (BEXPR_closure (i,ts1),_), e1),BEXPR_apply_direct(j,ts2,e2)
      | BEXPR_apply_direct (i,ts1,e1),BEXPR_apply( (BEXPR_closure(j,ts2),_),e2)
        when i = j
        ->
        assert (List.length ts1 = List.length ts2);
        teqns := combine ts1 ts2 @ !teqns;
        eqns := (e1,e2) :: !eqns

      *)

      | BEXPR_coerce (e,t), BEXPR_coerce (e',t') ->
        teqns := (t,t') :: !teqns;
        eqns := (e,e') :: !eqns

      | BEXPR_get_n (n1,e1), BEXPR_get_n (n2,e2) when n1 = n2 ->
        eqns := (e1,e2) :: !eqns

      | BEXPR_deref e1, BEXPR_deref e2  ->
        eqns := (e1,e2) :: !eqns

      (* CHEAT HERE .. ignore ts .. fix later *)
      | BEXPR_ref (i1,ts1), BEXPR_ref (i2,ts2) when i1 = i2 -> ()

      | (BEXPR_tuple ls1, BEXPR_tuple ls2)
        when List.length ls1 = List.length ls2 ->
        begin
          let rec merge e a b = match a,b with
          | [],[] -> e
          | ah :: at, bh :: bt -> merge ((ah,bh) :: e) at bt
          | _ -> assert false
          in
            eqns := merge !eqns ls1 ls2;
            s := None
        end

      | x,y ->
        (* the BTYP_void is a hack .. *)
        (*
        print_endline ("Terms do not match: " ^ sbe sym_table (x,BTYP_void) ^ " <-> " ^ sbe sym_table (y,BTYP_void));
        *)
        raise Not_found
      end
      ;
      begin match !s with
      | None -> ()
      | Some (i,t) ->
        (*
        print_endline ("Substituting " ^ si i ^ " -> " ^ sbt sym_table t);
        *)
        eqns :=
          List.map
          (fun (a,b) ->
            expr_term_subst a i t,
            expr_term_subst b i t
          )
          !eqns
        ;
        assert(not (List.mem_assoc i !mgu));
        mgu :=
          (i,t) ::
          (List.map
            (fun (j,t') -> j,expr_term_subst t' i t)
            !mgu
          )
      end
      ;
      loop ()
    in
      loop ();
      let tmgu = unification counter !teqns tdvars in
      tmgu,
      !mgu

let setoflist ls = List.fold_left (fun s i -> BidSet.add i s) BidSet.empty ls

let expr_maybe_matches counter tvars evars le re =
  let tvars = setoflist tvars in
  let evars = setoflist evars in
  let eqns = [le,re] in
  (*
  print_endline ("Expr unify: le = " ^ sbe sym_table le ^  "\nre = " ^ sbe sym_table re);
  *)
  try Some (expr_unification counter eqns tvars evars)
  with Not_found -> None
