(* TO BE CHANGED: the initialisation code for a module and root should be put in the
   SYMDEF_module and SYMDEF_root constructors instead of being wrapped in a function
   which happens to be called _init_ in the hope we can retrieve it, that's a hack!
*)
open Flx_ast
open Flx_types
open Flx_btype

let str_parent x = match x with | Some p -> string_of_int p | None -> "None"

type t = {
  sym_table: Flx_sym_table.t;
  pub_name_map: (string, Flx_btype.entry_set_t) Hashtbl.t;
  priv_name_map: (string, Flx_btype.entry_set_t) Hashtbl.t;
  mutable init_exes: sexe_t list;
  mutable exports: bound_iface_t list;
  mutable directives: sdir_t list;
}

let get_init_exes x = x.init_exes
let get_exports x = x.exports
let get_directives x = x.directives

let summary x =
  Flx_sym_table.summary x.sym_table ^ ", " ^ 
  string_of_int (Hashtbl.length x.pub_name_map) ^ " public names, " ^ 
  string_of_int (Hashtbl.length x.priv_name_map) ^ " private names, " ^
  string_of_int (List.length x.init_exes) ^ " initialisation instructions, " ^
  string_of_int (List.length x.exports) ^ " exports, " ^
  string_of_int (List.length x.directives) ^ " compiler directives "

let detail x = 
  let dsp v = match v with
  | NonFunctionEntry i -> string_of_int i.Flx_btype.base_sym
  | FunctionEntry ls -> "{" ^ String.concat "," (List.map (fun k -> string_of_int k.Flx_btype.base_sym) ls) ^ "}"
  in

  Flx_sym_table.detail x.sym_table ^"\n" ^
  "public names = " ^ Hashtbl.fold (fun k v acc -> acc ^"\n  "^k^": "^dsp v) x.pub_name_map "" ^ 
  "\nprivate names = " ^ Hashtbl.fold (fun k v acc -> acc ^"\n  "^k^": "^dsp v) x.priv_name_map ""  ^ 
  "\ninitialisation instructions: \n" ^ String.concat "\n" 
      (List.map (fun (sr,exe)->Flx_print.string_of_exe 2 exe) x.init_exes) ^
  "\ncompiler directives:\n"^ String.concat "\n" (List.map (fun (_,s) -> Flx_print.string_of_dir 2 s) x.directives) ^
  "\nexports:\n"^ String.concat "\n" (List.map 
      (fun (_,s,b) -> Flx_print.string_of_iface 2 s ^ 
        (match b with | None ->"" | Some i -> " <-- " ^ string_of_int i)) x.exports) 

let merge_entry_set htab k v =
(*
print_endline ("Merge entry " ^ k);
*)
  if Hashtbl.mem htab k then begin
    (*
    print_endline "Already in table, doing entryset merge";
    *)
    match Hashtbl.find htab k, v with
    | FunctionEntry ls1, FunctionEntry ls2 ->
      (* this isn't right! we should check for duplicates, but this is very hard 
       * it isn't just a matter of checking for uniqueness of the symbol indices,
       * since we could have multiple views of the same symbol. In the end, we
       * will just let overload resolution find the problem..
       *)
      Hashtbl.replace htab k (FunctionEntry (ls1 @ ls2))

    | NonFunctionEntry _, FunctionEntry _
    | FunctionEntry _, NonFunctionEntry _ ->
      failwith ("Duplicate and inconsistent entries for " ^ k ^ " on table merge")
 
    | NonFunctionEntry {base_sym=0;}, NonFunctionEntry {base_sym=0;} -> () (* no point adding another pointer to root *)
    | NonFunctionEntry _, NonFunctionEntry _ -> 
      failwith ("Duplicate non-function entries for " ^ k ^ " on table merge")
  end
  else begin 
(*
    print_endline ("Adding new symbol " ^ k ^ " to root");
*)
    Hashtbl.add htab k v
  end


(* use fresh variables, but preserve names *)
let mkentry counter_ref (vs:ivs_list_t) i =
  let is = List.map
    (fun _ -> Flx_mtypes2.fresh_bid counter_ref)
    (fst vs)
  in
  let ts = List.map (fun i -> btyp_type_var (i, btyp_type 0)) is in
  let vs = List.map2 (fun i (n,_,_) -> n,i) is (fst vs) in
  { Flx_btype.base_sym=i; spec_vs=vs; sub_ts=ts }


let merge_ivs
  (vs1,{ raw_type_constraint=con1; raw_typeclass_reqs=rtcr1 })
  (vs2,{ raw_type_constraint=con2; raw_typeclass_reqs=rtcr2 }) :
  ivs_list_t
  =
  let t =
    match con1,con2 with
    | TYP_tuple[], TYP_tuple[] -> TYP_tuple[]
    | TYP_tuple[],b -> b
    | a, TYP_tuple[] -> a
    | TYP_intersect a, TYP_intersect b ->
        TYP_intersect (a@b)
    | TYP_intersect a, b -> TYP_intersect (a @[b])
    | a, TYP_intersect b -> TYP_intersect (a::b)
    | a,b -> TYP_intersect [a;b]
  and
    rtcr = Flx_list.uniq_list (rtcr1 @ rtcr2)
  in
  vs1 @ vs2,
  { raw_type_constraint=t; raw_typeclass_reqs=rtcr }


let split_asms asms =
  let rec aux asms dcls exes ifaces dirs =
    match asms with
    | [] -> (dcls, exes, ifaces, dirs)
    | h :: t ->
      match h with
      | Exe (sr,exe) -> aux t dcls ((sr,exe) :: exes) ifaces dirs
      | Dcl (sr,id,seq,access,vs,dcl) -> aux t ((sr,id,seq,access,vs,dcl) :: dcls) exes ifaces dirs
      | Iface (sr,iface) -> aux t dcls exes ((sr,iface) :: ifaces) dirs
      | Dir dir -> aux t dcls exes ifaces (dir::dirs)
  in
    aux asms [] [] [] []


let dump_name_to_int_map level name name_map =
  let spc = Flx_util.spaces level in
  print_endline (spc ^ "//Name to int map for " ^ name);
  print_endline (spc ^ "//---------------");
  Hashtbl.iter
  (
    fun id n ->
      print_endline ( "//" ^ spc ^ id ^ ": " ^ string_of_int n)
  )
  name_map
  ;
  print_endline ""


let strp = function | Some x -> string_of_int x | None -> "none"


let full_add_unique counter_ref sym_table sr (vs:ivs_list_t) table key value =
  try
    let entry = Hashtbl.find table key in
    match entry with
    | NonFunctionEntry (idx)
    | FunctionEntry (idx :: _ ) ->
        let sym = Flx_sym_table.find sym_table (Flx_typing.sye idx) in
        Flx_exceptions.clierr2 sr sym.Flx_sym.sr (
          "[build_tables] Duplicate non-function " ^ key ^ "<" ^
          Flx_print.string_of_bid (Flx_typing.sye idx) ^ ">")

    | FunctionEntry [] -> assert false
  with Not_found ->
    Hashtbl.add table key (NonFunctionEntry (mkentry counter_ref vs value))


let full_add_typevar counter_ref sym_table sr table key value =
  try
    let entry = Hashtbl.find table key in
    match entry with
    | NonFunctionEntry (idx)
    | FunctionEntry (idx :: _ ) ->
        let sym = Flx_sym_table.find sym_table (Flx_typing.sye idx) in
        Flx_exceptions.clierr2 sr sym.Flx_sym.sr (
         "[build_tables] Duplicate non-function " ^ key ^ "<" ^
         Flx_print.string_of_bid (Flx_typing.sye idx) ^ ">")

    | FunctionEntry [] -> assert false
  with Not_found ->
    Hashtbl.add table key (NonFunctionEntry (mkentry counter_ref dfltvs value))


let full_add_function counter_ref sym_table sr (vs:ivs_list_t) table key value =
  try
    match Hashtbl.find table key with
    | NonFunctionEntry entry ->
        let sym = Flx_sym_table.find sym_table (Flx_typing.sye entry) in
        Flx_exceptions.clierr2 sr sym.Flx_sym.sr (
          "[build_tables] Cannot overload " ^
          key ^ "<" ^ Flx_print.string_of_bid value ^ ">" ^
          " with non-function " ^
          sym.Flx_sym.id ^ "<" ^
          Flx_print.string_of_bid (Flx_typing.sye entry) ^ ">")

    | FunctionEntry fs ->
        Hashtbl.remove table key;
        Hashtbl.add table key (FunctionEntry (mkentry counter_ref vs value :: fs))
  with Not_found ->
    Hashtbl.add table key (FunctionEntry [mkentry counter_ref vs value])


(* make_ivs inserts unique indexes into vs_lists, thus creating an ivs_list. *)
let make_ivs ?(print=false) level counter_ref (vs, con) : ivs_list_t =
  let ivs =
    List.map begin fun (tid, tpat) ->
      let n = Flx_mtypes2.fresh_bid counter_ref in
      if print then
        print_endline ("//  " ^ Flx_util.spaces level ^
          Flx_print.string_of_bid n ^ " -> " ^ tid ^ " (type variable)");
      tid, n, tpat
    end vs
  in
  ivs, con


(* this routine takes a partially filled unbound definition table,
  'sym_table' and a counter 'counter', and adds entries to the table
  at locations equal to and above the counter

  Each entity is also added to the name map of the parent entity.

  We use recursive descent, noting that the whilst an entity
  is not registered until its children are completely registered,
  its index is allocated before descending into child structures,
  so the index of children is always higher than its parent numerically

  The parent index is passed down so an uplink to the parent can
  be created in the child, but it cannot be followed until
  registration of all the children and their parent is complete
*)

let add_root_entry counter_ref name_map =
  Hashtbl.add name_map "root"
    (NonFunctionEntry (mkentry counter_ref dfltvs 0))

let rec build_tables
  ~pub_name_map
  ~priv_name_map
  print_flag
  counter_ref
  sym_table
  name
  inherit_ivs
  level
  parent
  asms
=
  (* Split up the assemblies into their repsective types. split_asms returns
   * reversed lists, so we must undo that. *)
  let dcls, exes, ifaces, dirs = split_asms asms in
  let dcls, exes, ifaces, dirs =
    List.rev dcls, List.rev exes, List.rev ifaces, List.rev dirs
  in
(*
print_endline ("Level " ^string_of_int level ^ " build tables, exports = " ^ string_of_int (List.length ifaces));
*)
  (* Add the parent to each interface *)
  let ifaces = List.map (fun (i,j)-> i, j, parent) ifaces in
  let interfaces = ref ifaces in

  (* check root index. Error out if it's an invalid root. *)
  if level = 0 then
    match dcls with
    | [x] -> ()
    | _ -> failwith "Expected top level to contain root declaration"
  else
    if name = "root" then
      failwith ("Can't name non-toplevel module 'root'")
    else 
      add_root_entry counter_ref priv_name_map
  ;
  let inner_interfaces = 
    add_dcls
      print_flag
      counter_ref
      sym_table
      name
      inherit_ivs
      level
      parent
      pub_name_map
      priv_name_map
      dcls
  in
(*
print_endline ("Interfaces level " ^string_of_int level ^  " = " ^
       string_of_int (List.length (!interfaces)) ^ " + " ^ 
        string_of_int (List.length inner_interfaces));
*)
  pub_name_map, priv_name_map, exes, (!interfaces) @ inner_interfaces, dirs

and add_dcls 
  print_flag 
  counter_ref 
  sym_table 
  name 
  inherit_ivs 
  level 
  parent 
  pub_name_map 
  priv_name_map 
  dcls
=
  let interfaces_ref = ref [] in
  List.iter (fun dcl ->
    ignore(build_table_for_dcl
      print_flag
      counter_ref
      sym_table
      name
      inherit_ivs
      level
      parent
      pub_name_map
      priv_name_map
      interfaces_ref
      dcl)
  ) dcls;
  !interfaces_ref



(** Add the symbols from one declaration. *)
and build_table_for_dcl
  print_flag
  counter_ref
  sym_table
  name
  inherit_ivs
  level
  parent
  pub_name_map
  priv_name_map
  interfaces
  (sr, id, seq, access, vs, dcl)
=

  (* Make some shorthand functions *)
  let spc = Flx_util.spaces level in
  let make_ivs = make_ivs ~print:print_flag level counter_ref in

  if print_flag then
    print_endline (Flx_print.string_of_dcl level id seq vs dcl);

  (* Determine the next index to use. If we already have a symbol index,
   * use that, otherwise use the next number in the counter. *)
  let symbol_index =
    match seq with
    | Some n -> n
    | None -> Flx_mtypes2.fresh_bid counter_ref
  in

  if print_flag then
    print_endline ("Flx_symtab: Adding " ^ id^"="^string_of_int symbol_index)
  ;
  (* Update the type variable list to include the index. *)
  let ivs = make_ivs vs in

  let add_unique table id idx = full_add_unique
    counter_ref
    sym_table
    sr
    (merge_ivs ivs inherit_ivs)
    table
    id
    idx
  in
  let add_function table id idx = full_add_function
    counter_ref
    sym_table
    sr
    (merge_ivs ivs inherit_ivs)
    table
    id
    idx
  in

  (* Add the symbol to the symbol table. *)
  let add_symbol
    ?(parent=parent)
    ?(ivs=ivs)
    ?pubtab
    ?privtab
    ?(dirs=[])
    index
    id
    symdef
  =
(*
    print_endline ("Flx_symtab:raw add_symbol: " ^ id^"="^string_of_int index ^ ", parent=" ^ str_parent parent);
*)
    let pubtab =
      match pubtab with
      | Some pubtab -> pubtab
      | None -> Hashtbl.create 0
    in
    let privtab =
      match privtab with
      | Some privtab -> privtab
      | None -> Hashtbl.create 0
    in
    Flx_sym_table.add sym_table index parent {
      Flx_sym.id = id;
      sr = sr;
      vs = ivs;
      pubmap = pubtab;
      privmap = privtab;
      dirs = dirs;
      symdef = symdef;
    }
  in

  let add_tvars' parent table ivs =
    List.iter begin fun (tvid, index, tpat) ->
      let mt = match tpat with
      | TYP_patany _ -> TYP_type (* default/unspecified *)
      | TYP_none -> TYP_type
      | TYP_ellipsis -> Flx_exceptions.clierr sr "Ellipsis ... as metatype"
      | _ -> tpat
      in

      (* Add the type variable to the symbol table. *)
      add_symbol ~ivs:dfltvs index tvid (SYMDEF_typevar mt);
      full_add_typevar counter_ref sym_table sr table tvid index;
    end (fst ivs)
  in
  let add_tvars table = add_tvars' (Some symbol_index) table ivs in

  let add_parameter pubtab privtab parent (k, name, typ, dflt) =
    let n = Flx_mtypes2.fresh_bid counter_ref in

    if print_flag then
      print_endline ("//  " ^ spc ^ Flx_print.string_of_bid n ^ " -> " ^
        name ^ " (parameter)");

    (* Add the paramater to the symbol table. *)
    add_symbol ~parent ~ivs:dfltvs n name (SYMDEF_parameter (k, typ));

    (* Possibly add the parameter to the public symbol table. *)
    if access = `Public then
      full_add_unique counter_ref sym_table sr dfltvs pubtab name n;

    (* Add the parameter to the private symbol table. *)
    full_add_unique counter_ref sym_table sr dfltvs privtab name n;

    (k, name, typ, dflt)
  in

  (* Add parameters to the symbol table. *)
  let add_parameters pubtab privtab parent =
    List.map (add_parameter pubtab privtab parent)
  in

  (* Add simple parameters to the symbol table. *)
  let add_simple_parameters pubtab privtab parent =
    List.map begin fun (name, typ) ->
      add_parameter pubtab privtab parent (`PVal, name, typ, None)
    end
  in

  (* dummy-ish temporary symbol tables could contain type vars for looking
   * at this declaration. *)
  let pubtab = Hashtbl.create 3 in
  let privtab = Hashtbl.create 3 in

  (* Add the declarations to the symbol table. *)
  begin match (dcl:Flx_types.dcl_t) with
  | DCL_reduce (ps, e1, e2) ->
      let ips = add_simple_parameters pubtab privtab (Some symbol_index) ps in

      (* Add the symbol to the symbol table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_reduce (ips, e1, e2));

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_axiom ((ps, pre), e1) ->
      let ips = add_parameters pubtab privtab (Some symbol_index) ps in

      (* Add the symbol to the symbol table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_axiom ((ips, pre),e1));

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_lemma ((ps, pre), e1) ->
      let ips = add_parameters pubtab privtab (Some symbol_index) ps in

      (* Add the symbol to the symbol table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_lemma ((ips, pre), e1));

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_function ((ps,pre),t,props,asms) ->
      let is_ctor = List.mem `Ctor props in

      if is_ctor && id <> "__constructor__" then
        Flx_exceptions.syserr sr
          "Function with constructor property not named __constructor__";

      if is_ctor then
        begin match t with
        | TYP_void _ -> ()
        | _ -> Flx_exceptions.syserr sr "Constructor should return type void"
        end;

      (* change the name of a constructor to the class name prefixed by
       * _ctor_. *)
      let id = if is_ctor then "_ctor_" ^ name else id in

      let t = if t = TYP_none then TYP_var symbol_index else t in
      let pubtab, privtab, exes, ifaces, dirs =
        build_tables
          ~pub_name_map:(Hashtbl.create 97)
          ~priv_name_map:(Hashtbl.create 97)
          print_flag
          counter_ref
          sym_table
          id
          dfltvs
          (level + 1)
          (Some symbol_index)
          asms
      in

      let ips = add_parameters pubtab privtab (Some symbol_index) ps in

      (* Add the symbols to the sym_table. *)
      add_symbol ~pubtab ~privtab
        symbol_index id (SYMDEF_function ((ips, pre), t, props, exes));

      (* Possibly add the function to the public symbol table. *)
      if access = `Public then add_function pub_name_map id symbol_index;

      (* Add the function to the private symbol table. *)
      add_function priv_name_map id symbol_index;

      (* Add the interface. *)
      interfaces := !interfaces @ ifaces;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_match_check (pat,(mvname,match_var_index)) ->
      assert (List.length (fst ivs) = 0);

      (* Add the symbol to sym_table. *)
      add_symbol ~pubtab ~privtab symbol_index id
        (SYMDEF_match_check (pat, (mvname, match_var_index)));

      (* Possibly add the function to the public symbol table. *)
      if access = `Public then add_function pub_name_map id symbol_index;

      (* Add the function to the private symbol table. *)
      add_function priv_name_map id symbol_index;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_match_handler (pat,(mvname,match_var_index),asms) ->
      assert (List.length (fst ivs) = 0);
      let vars = Hashtbl.create 97 in
      Flx_mbind.get_pattern_vars vars pat [];

      let new_asms = ref asms in
      Hashtbl.iter begin fun vname (sr,extractor) ->
        let component =
          Flx_mbind.gen_extractor
            extractor
            (EXPR_index (sr,mvname,match_var_index))
        in
        let dcl =
          Dcl (sr, vname, None,`Private, dfltvs,
            DCL_value (TYP_typeof (component), `Val))
        and instr = Exe (sr, EXE_init (vname, component)) in
        new_asms := dcl :: instr :: !new_asms;
      end vars;

      let pubtab, privtab, exes, ifaces, dirs =
        build_tables
          ~pub_name_map:(Hashtbl.create 97)
          ~priv_name_map:(Hashtbl.create 97)
          print_flag
          counter_ref
          sym_table
          id
          dfltvs
          (level + 1)
          (Some symbol_index)
          !new_asms
      in

      (* Add symbols to sym_table. *)
      add_symbol ~pubtab ~privtab ~dirs symbol_index id (SYMDEF_function (
          ([],None),
          TYP_var symbol_index,
          [`Generated "symtab:match handler" ; `Inline],
          exes));

      (* Possibly add function to public symbol table. *)
      if access = `Public then add_function pub_name_map id symbol_index;

      (* Add function to private symbol table. *)
      add_function priv_name_map id symbol_index;

      (* Add interface *)
      interfaces := !interfaces @ ifaces;

      (* Add type variables to private symbol table. *)
      add_tvars privtab

  | DCL_insert (s,ikind,reqs) ->
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_insert (s,ikind,reqs));

      (* Possibly add the inserted function to the public symbol table. *)
      if access = `Public then add_function pub_name_map id symbol_index;

      (* Add the inserted function to the private symbol table. *)
      add_function priv_name_map id symbol_index

  | DCL_root asms ->
      let pubtab, privtab, exes, ifaces, dirs =
        build_tables
          ~pub_name_map:(Hashtbl.create 97)
          ~priv_name_map:(Hashtbl.create 97)
          print_flag
          counter_ref
          sym_table
          id
          (merge_ivs inherit_ivs ivs)
          (level + 1)
          (Some 0)
          asms
      in
      (* Add the module to the sym_table. *)
      begin 
        let entry:Flx_sym_table.elt = try Hashtbl.find sym_table 0 with Not_found -> failwith "Flx_symtab: no root in symbol table" in
        let sym:Flx_sym.t = match entry with { Flx_sym_table.sym=sym } -> sym in
        match sym with {Flx_sym.pubmap=old_pubmap; privmap=old_privmap; dirs=old_dirs; symdef=symdef} ->
        Hashtbl.iter (fun k v -> merge_entry_set old_pubmap k v) pubtab;
        Hashtbl.iter (fun k v -> merge_entry_set old_privmap k v) privtab;
        let symdef = match symdef with 
        | SYMDEF_root old_exes -> SYMDEF_root (old_exes @ exes) (* ORDER OF INITIALISATION IS VITAL *)
        | _ -> failwith "flx_symtab: expected index 0 to be SYMDEF_root!"
        in
        let dirs = old_dirs @ dirs in
        let sym = { sym with Flx_sym.dirs=dirs ; symdef=symdef } in
        let entry = { entry with Flx_sym_table.sym=sym; } in
        Hashtbl.replace sym_table 0 entry
      end;
      (* Add the interface. *)
      interfaces := !interfaces @ ifaces

  | DCL_module asms ->
      let complete_vs = merge_ivs inherit_ivs ivs in
      let pubtab, privtab, exes, ifaces, dirs =
        build_tables
          ~pub_name_map:(Hashtbl.create 97)
          ~priv_name_map:(Hashtbl.create 97)
          print_flag
          counter_ref
          sym_table
          id
          complete_vs
          (level + 1)
          (Some symbol_index)
          asms
      in
      (* Add the module to the sym_table. *)
(*
print_endline ("Adding module " ^ id ^ " parent " ^ (match parent with | Some p -> string_of_int p | None -> "None"));
*)
      add_symbol ~pubtab ~privtab ~dirs symbol_index id (SYMDEF_module exes);

      (* Possibly add module to the public symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add the module to the private symbol table. *)
      add_unique priv_name_map id symbol_index;

      (* WARNING: this is bugged for polymorphic modules, can't get that to work.
         the call is only generated in flx_desugar for non-polymorphic modules
         so we should only add an init function for them
      *)
      if complete_vs = dfltvs then begin
        (* Take all the exes and add them to a function called _init_ that's
         * called when the module is loaded. *)
        let init_def = SYMDEF_function (([], None), TYP_void sr, [], exes) in

        (* Get a unique index for the _init_ function. *)
        let n' = Flx_mtypes2.fresh_bid counter_ref in

        if print_flag then
          print_endline ("//  " ^ spc ^ Flx_print.string_of_bid n' ^
          " -> _init_  (module " ^ id ^ ")");

        (* Add the _init_ function to the sym_table. *)
        add_symbol ~parent:(Some symbol_index) n' "_init_" init_def;
        (* Possibly add the _init_ function to the public symbol table. *)
        if access = `Public then add_function pubtab "_init_" n';

        (* Add the _init_ function to the symbol table. *)
        add_function privtab "_init_" n'
      end
      ;

      (* Add the interface. *)
      interfaces := !interfaces @ ifaces;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_typeclass asms ->
      let complete_vs = merge_ivs inherit_ivs ivs in
      let pubtab, privtab, exes, ifaces, dirs =
        build_tables
          ~pub_name_map:(Hashtbl.create 97)
          ~priv_name_map:(Hashtbl.create 97)
          print_flag
          counter_ref
          sym_table
          id
          complete_vs
          (level + 1)
          (Some symbol_index)
          asms
      in
      let fudged_privtab = Hashtbl.create 97 in
      let vsl = List.length (fst inherit_ivs) + List.length (fst ivs) in

      let drop vs =
        let keep = List.length vs - vsl in
        if keep >= 0 then
          List.rev (Flx_list.list_prefix (List.rev vs) keep)
        else
          failwith "WEIRD CASE"
      in
      let nts = List.map (fun (s,i,t)-> btyp_type_var (i,btyp_type 0)) (fst ivs) in

      (* fudge the private view to remove the vs *)
      let fixup e =
        { e with
          Flx_btype.spec_vs=drop e.Flx_btype.spec_vs;
          sub_ts=nts @ drop e.Flx_btype.sub_ts }
      in

      Hashtbl.iter begin fun s es ->
        let nues =
          if s = "root" then es else
          match es with
          | NonFunctionEntry e -> NonFunctionEntry (fixup e)
          | FunctionEntry es -> FunctionEntry (List.map fixup es)
        in
        Hashtbl.add fudged_privtab s nues
      end privtab;

      (* Add the typeclass to the sym_table. *)
      add_symbol
        ~pubtab
        ~privtab:fudged_privtab
        ~dirs
        symbol_index id SYMDEF_typeclass;

      if complete_vs = dfltvs then begin
        (* Take all the exes and add them to a function called _init_ that's
         * called when the module is loaded. *)
        let init_def = SYMDEF_function (([], None), TYP_void sr, [], exes) in

        (* Get a unique index for the _init_ function. *)
        let n' = Flx_mtypes2.fresh_bid counter_ref in

        if print_flag then
          print_endline ("//  " ^ spc ^ Flx_print.string_of_bid n' ^
          " -> _init_  (class " ^ id ^ ")");

        (* Add the _init_ function to the sym_table. *)
        add_symbol ~parent:(Some symbol_index) n' "_init_" init_def;

        (* Possibly add the _init_ function to the public symbol table. *)
        if access = `Public then add_function pubtab "_init_" n';

        (* Add the _init_ function to the symbol table. *)
        add_function fudged_privtab "_init_" n'
      end
      ;

      (* Possibly add the typeclass to the public symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add the typeclass to the private symbol table. *)
      add_unique priv_name_map id symbol_index;

      (* Add the interface. *)
      interfaces := !interfaces @ ifaces;

      (* Add the type variables to the private symbol table. *)
      add_tvars fudged_privtab

  | DCL_instance (qn,asms) ->
      let pubtab, privtab, exes, ifaces, dirs =
        build_tables
          ~pub_name_map:(Hashtbl.create 97)
          ~priv_name_map:(Hashtbl.create 97)
          print_flag
          counter_ref
          sym_table
          id
          dfltvs
          (level + 1)
          (Some symbol_index)
          asms
      in

      (* Add typeclass instance to the sym_table. *)
      add_symbol ~pubtab ~privtab ~dirs symbol_index id (SYMDEF_instance qn);

      (* Prepend _inst_ to the name of the instance.
       * XXX: Why do we need this? *)
      let inst_name = "_inst_" ^ id in

      (* Possibly add the typeclass instance to the public symbol table. *)
      if access = `Public then add_function pub_name_map inst_name symbol_index;

      (* Add the typeclass instance to the private symbol table. *)
      add_function priv_name_map inst_name symbol_index;

      (* Add the interface. *)
      interfaces := !interfaces @ ifaces;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_value (t, kind) ->
      let t = match t with | TYP_none -> TYP_var symbol_index | _ -> t in

      let symdef =
        match kind with
        | `Val -> SYMDEF_val t
        | `Var -> SYMDEF_var t
        | `Ref -> SYMDEF_ref t
        | `Lazy e -> SYMDEF_lazy (t, e)
      in

      (* Add the value to the dnfs. *)
      add_symbol ~pubtab ~privtab symbol_index id symdef;

      (* Possibly add the value to the public symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add the value to the private symbol table. *)
      add_unique priv_name_map id symbol_index;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_type_alias t ->
      (* Add the type alias to the sym_table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_type_alias t);

      (* this is a hack, checking for a type function this way, since it will
       * also incorrectly recognize a type lambda like:
       *
       *    typedef f = fun(x:TYPE)=>x;
       *
       * With ordinary functions:
       *
       *    f := fun (x:int)=>x;
       *
       * initialises a value, and this f cannot be overloaded.
       *
       * That is, a closure (object) and a function (class) are distinguished ..
       * this should be the same for type functions as well.
       *
       * EVEN WORSE: our system is getting confused with unbound type variables
       * which are HOLES in types, and parameters, which are bound variables:
       * the latter are really just the same as type aliases where the alias
       * isn't known. The problem is that we usually substitute names with
       * what they alias, but we can't for parameters, so we replace them with
       * undistinguished type variables.
       *
       * Consequently, for a type function with a type function as a parameter,
       * the parameter name is being overloaded when it is applied, which is
       * wrong.
       *
       * We need to do what we do with ordinary function: put the parameter
       * names into the symbol table too: lookup_name_with_sig can handle this,
       * because it checks both function set results and non-function results.
       *)
      begin match t with
      | TYP_typefun _ ->
          if access = `Public then add_function pub_name_map id symbol_index;
          add_function priv_name_map id symbol_index
      | _ ->
          if access = `Public then add_unique pub_name_map id symbol_index;
          add_unique priv_name_map id symbol_index
      end;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_inherit qn ->
      (* Add the inherited typeclass to the dnfs. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_inherit qn);

      (* Possibly add the inherited typeclass to the public symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add the inherited typeclass to the private symbol table. *)
      add_unique priv_name_map id symbol_index;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_inherit_fun qn ->
      (* Add the inherited function to the dnfs. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_inherit_fun qn);

      (* Possibly add the inherited function to the public symbol table. *)
      if access = `Public then add_function pub_name_map id symbol_index;

      (* Add the inherited function to the private symbol table. *)
      add_function priv_name_map id symbol_index;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_newtype t ->
      (* Add the newtype to the sym_table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_newtype t);

      (* Create an identity function that doesn't do anything. *)
      let ts = List.map (fun (n,_) -> TYP_name (sr,n,[])) (fst vs) in
      let piname = TYP_name (sr,id,ts) in

      (* XXX: What's the _repr_ function for? *)
      (* ANS: it gets the representation of the abstract type *)
      let n_repr = Flx_mtypes2.fresh_bid counter_ref in

      (* Add the _repr_ function to the symbol table. *)
      add_symbol ~pubtab ~privtab n_repr "_repr_" (SYMDEF_fun (
        [],
        [piname],
        t,
        Flx_code_spec.Identity,
        NREQ_true
        ,
        "expr"));

      (* Add the _repr_ function to the sym_table. *)
      add_function priv_name_map "_repr_" n_repr;

      (* XXX: What's the _make_ function for? *)
      (* ANS: its a type constructor for the abstract type, made from representation *)
      let n_make = Flx_mtypes2.fresh_bid counter_ref in

      (* Add the _make_ function to the symbol table. *)
      add_symbol ~pubtab ~privtab n_make ("_make_" ^ id) (SYMDEF_fun (
        [],
        [t],
        piname,
        Flx_code_spec.Identity,
        NREQ_true,
        "expr"));

      (* Add the _make_ function to the sym_table. *)
      add_function priv_name_map ("_make_" ^ id) n_make;

      (* Possibly add the _make_ function to the public symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add the _make_ function to the private symbol table. *)
      add_unique priv_name_map id symbol_index;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_abs (quals, c, reqs) ->
      (* Add the abs to the sym_table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_abs (quals, c, reqs));

      (* Possibly add the abs to the private symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add the abs to the public symbol table. *)
      add_unique priv_name_map id symbol_index;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_const (props, t, c, reqs) ->
      let t = if t = TYP_none then TYP_var symbol_index else t in

      (* Add the const to the sym_table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_const (props, t, c, reqs));

      (* Possibly add the const to the private symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add the const public symbol table. *)
      add_unique priv_name_map id symbol_index;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_fun (props, ts,t,c,reqs,prec) ->
      (* Add the function to the sym_table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_fun (props, ts, t, c, reqs, prec));

      (* Possibly add the function to the public symbol table. *)
      if access = `Public then add_function pub_name_map id symbol_index;

      (* Add the function to the private symbol table. *)
      add_function priv_name_map id symbol_index;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  (* A callback is just like a C function binding .. only it actually generates
   * the function. It has a special argument the C function has as type void*,
   * but which Felix must consider as the type of a closure with the same type
   * as the C function, with this void* dropped. *)
  | DCL_callback (props, ts,t,reqs) ->
      (* Add the callback to the sym_table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_callback (props, ts, t, reqs));

      (* Possibly add the callback to the public symbol table. *)
      if access = `Public then add_function pub_name_map id symbol_index;

      (* Add the callback to the private symbol table. *)
      add_function priv_name_map id symbol_index;

      (* Add the type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_union (its) ->
      let tvars = List.map (fun (s,_,_)-> TYP_name (sr,s,[])) (fst ivs) in
      let utype = TYP_name (sr, id, tvars) in
      let its =
        let ccount = ref 0 in (* count component constructors *)
        List.map begin fun (component_name,v,vs,t) ->
          (* ctor sequence in union *)
          let ctor_idx = match v with
          | None ->  !ccount
          | Some i -> ccount := i; i
          in
          incr ccount;
          component_name, ctor_idx, vs, t
        end its
      in

      (* Add union to sym_table. *)
      add_symbol ~pubtab ~privtab symbol_index id (SYMDEF_union its);

      (* Possibly add union to the public symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add the union to the private symbol table. *)
      add_unique priv_name_map id symbol_index;

      let unit_sum =
        List.fold_left begin fun v (_,_,_,t) ->
          v && (match t with TYP_void _ -> true | _ -> false)
        end true its
      in
      List.iter begin fun (component_name, ctor_idx, vs, t) ->
        let dfn_idx = Flx_mtypes2.fresh_bid counter_ref in (* constructor *)
        let match_idx = Flx_mtypes2.fresh_bid counter_ref in (* matcher *)

        (* existential type variables *)
        let evs = make_ivs vs in
        add_tvars' (Some dfn_idx) privtab evs;
        let ctor_dcl2 =
          if unit_sum then begin
            if access = `Public then add_unique pub_name_map component_name dfn_idx;
            add_unique priv_name_map component_name dfn_idx;
            SYMDEF_const_ctor (symbol_index, utype, ctor_idx, evs)
          end else
            match t with
            | TYP_void _ -> (* constant constructor *)
                if access = `Public then add_unique pub_name_map component_name dfn_idx;
                add_unique priv_name_map component_name dfn_idx;
                SYMDEF_const_ctor (symbol_index, utype, ctor_idx, evs)

            | TYP_tuple ts -> (* non-constant constructor or 2 or more arguments *)
                if access = `Public then add_function pub_name_map component_name dfn_idx;
                add_function priv_name_map component_name dfn_idx;
                SYMDEF_nonconst_ctor (symbol_index, utype, ctor_idx, evs, t)

            | _ -> (* non-constant constructor of 1 argument *)
                if access = `Public then add_function pub_name_map component_name dfn_idx;
                add_function priv_name_map component_name dfn_idx;
                SYMDEF_nonconst_ctor (symbol_index, utype, ctor_idx, evs, t)
        in

        if print_flag then
          print_endline ("//  " ^ spc ^ Flx_print.string_of_bid dfn_idx ^
            " -> " ^ component_name);

        (* Add the component to the sym_table. *)
        add_symbol ~pubtab ~privtab dfn_idx component_name ctor_dcl2;
      end its;

      (* Add type variables to the private symbol table. *)
      add_tvars privtab

  | DCL_cstruct (sts, reqs) ->
      let tvars = List.map (fun (s,_,_)-> `AST_name (sr,s,[])) (fst ivs) in
      let stype = `AST_name(sr, id, tvars) in

      (* Add symbols to sym_table *)
      add_symbol ~pubtab ~privtab symbol_index id ( SYMDEF_cstruct (sts, reqs));

      (* Possibly add the struct to the public symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add struct to the private symbol table. *)
      add_unique priv_name_map id symbol_index;

      (* Add type variables to the private symbol table. *)
      add_tvars privtab


  | DCL_struct sts ->
      let tvars = List.map (fun (s,_,_)-> `AST_name (sr,s,[])) (fst ivs) in
      let stype = `AST_name(sr, id, tvars) in

      (* Add symbols to sym_table *)
      add_symbol ~pubtab ~privtab symbol_index id ( SYMDEF_struct sts);

      (* Possibly add the struct to the public symbol table. *)
      if access = `Public then add_unique pub_name_map id symbol_index;

      (* Add struct to the private symbol table. *)
      add_unique priv_name_map id symbol_index;

      (* Add type variables to the private symbol table. *)
      add_tvars privtab

      (* NOTE: we don't add a type constructor for struct, because it would have
       * the same name as the struct type ..  we just check this case as
       * required *)
  end;
  symbol_index


let make sym_table =
  {
    sym_table = sym_table;
    pub_name_map = Hashtbl.create 97;
    priv_name_map = Hashtbl.create 97;
    init_exes = [];
    exports = [];
    directives = [];
  }

let add_dcl ?parent print_flag counter_ref symbol_table dcl =
  let level, pubmap, privmap =
    match parent with
    | Some index ->
        let sym = Flx_sym_table.find symbol_table.sym_table index in
        1, sym.Flx_sym.pubmap, sym.Flx_sym.privmap
    | None ->
        0, symbol_table.pub_name_map, symbol_table.priv_name_map
  in

  let interfaces = ref [] in
  let symbol_index =
    build_table_for_dcl
      print_flag
      counter_ref
      symbol_table.sym_table
      "root"
      Flx_ast.dfltvs
      level
      parent
      pubmap
      privmap
      interfaces
      dcl
  in
  symbol_index, !interfaces


(* Add the assemblies to the symbol table. *)
let add_asms 
  (print_flag:bool) 
  (counter_ref:bid_t ref) 
  (symbol_table:t)
  (name:string)
  (level:int) 
  (parent:bid_t option) 
  asms
=
  let _, _, exes, interfaces, dirs =
    build_tables
      ~pub_name_map:symbol_table.pub_name_map
      ~priv_name_map:symbol_table.priv_name_map
      print_flag
      counter_ref
      symbol_table.sym_table
      name (* "root" *)
      dfltvs
      level (*0*)
      parent (*None*)
      asms
  in
  symbol_table.init_exes <- symbol_table.init_exes @ exes;
  symbol_table.exports <- symbol_table.exports @ interfaces;
  symbol_table.directives <- symbol_table.directives @ dirs
(*
;print_endline ("Add asms .. exports: " ^ string_of_int (List.length symbol_table.exports));
*)
