(*
 * Main driver code
 *)

type state_t = {
  syms: Flx_mtypes2.sym_state_t;
  bbdfns: Flx_types.fully_bound_symbol_table_t;
  macro_state: Flx_macro.macro_state_t;
  desugar_state: Flx_desugar.desugar_state_t;
  symtab: Flx_symtab.t;
  bbind_state: Flx_bbind.bbind_state_t;
  module_index: int;
  init_index: int;
}


(* Create the global state needed for compilation *)
let create_state options =
  (* Construct the state needed for compilation *)
  let syms = Flx_mtypes2.make_syms options in
  let symtab = Flx_symtab.make syms in
  let bbdfns = Hashtbl.create 97 in

  (* Declare the module to work within *)
  let module_index, _ = Flx_symtab.add_dcl symtab (
    Flx_srcref.dummy_sr, "__init_module__", None, `Public, Flx_ast.dfltvs,
    Flx_types.DCL_module [])
  in
  let module_symbol = Hashtbl.find syms.Flx_mtypes2.dfns module_index in

  (* Find the module's _init_ function *)
  let init_index =
    match Hashtbl.find module_symbol.Flx_types.pubmap "_init_" with
    | Flx_types.FunctionEntry [ { Flx_types.base_sym=base_sym } ] -> base_sym
    | _ -> assert false
  in
  {
    syms = syms;
    bbdfns = bbdfns;
    macro_state = Flx_macro.make_macro_state "<input>";
    desugar_state = Flx_desugar.make_desugar_state "<input>" syms;
    symtab = symtab;
    bbind_state = Flx_bbind.make_bbind_state syms bbdfns;
    module_index = module_index;
    init_index = init_index;
  }


(* Add an execution to symtab. *)
let add_exe_to_symtab state exe =
  (* Look up the _init_ function in symtab. *)
  let symbol = Hashtbl.find state.syms.Flx_mtypes2.dfns state.init_index in

  (* Create a new _init_ function that appends the exe. *)
  let symbol =
    match symbol.Flx_types.symdef with
    | Flx_types.SYMDEF_function (p, t, ps, exes) ->
        { symbol with
          Flx_types.symdef=Flx_types.SYMDEF_function (p, t, ps, exes @ [exe]) }
    | _ -> assert false
  in
  (* And then replace the old _init_ symbol with the new one. *)
  Hashtbl.replace state.syms.Flx_mtypes2.dfns state.init_index symbol


(* Process the stdin input statements *)
let handle_stmt state stmt () =
  print_endline ("... PARSED:    " ^ (Flx_print.string_of_statement 0 stmt));

  Flx_macro.expand_macros_in_statement state.macro_state begin fun stmt () ->
    print_endline ("... EXPANDED:  " ^ (Flx_print.string_of_statement 0 stmt));
  end stmt ();

  Flx_desugar.desugar_statement state.desugar_state begin fun asm () ->
    print_endline ("... DESUGARED: " ^ (Flx_print.string_of_asm 0 asm));

    (* We need to save the symbol index counter so we can bind all of the
     * symbols that we just added. *)
    let i = ref !(state.syms.Flx_mtypes2.counter) in

    (* Add declarations to the symbol table *)
    begin
      match asm with
      | Flx_types.Exe exe -> add_exe_to_symtab state exe
      | Flx_types.Dcl dcl ->
          let _ = Flx_symtab.add_dcl ?parent:(Some state.module_index)
            state.symtab dcl in
          ()
      | Flx_types.Iface _ -> ()
      | Flx_types.Dir _ -> ()
    end;

    (* Now bind in order all of the symbols we added. *)
    while !i < !(state.syms.Flx_mtypes2.counter) do
      let entry =
        try Some (Hashtbl.find state.syms.Flx_mtypes2.dfns !i)
        with Not_found -> None
      in
      begin
        match entry with
        | Some entry ->
          Flx_bbind.bbind_symbol state.bbind_state !i entry;

          (* Look up the bound value in the bbdnfs *)
          let _, _, _, e = Hashtbl.find state.bbdfns !i in
          print_endline ("... BOUND:     " ^ Flx_print.string_of_bbdcl
            state.syms.Flx_mtypes2.dfns
            state.bbdfns
            e
            !i);
        | None -> ()
      end;
      incr i
    done;
    ()
  end stmt ();

  print_string " >>> "; flush stdout;
  ()


(* Parse all the imports *)
let parse_imports handle_stmt init =
  let parser_state =
    List.fold_left begin fun parser_state name ->
      Flx_parse.parse_file
        ~include_dirs:!Options.include_dirs
        parser_state
        name
    end
    (Flx_parse.make_parser_state handle_stmt init)
    (List.rev !Options.imports)
  in

  (*
  (* The statements are constructed in reverse *)
  let stmts = List.rev stmts in

  (* Desugar all the statements *)
  let asms = Flx_desugar.desugar_compilation_unit state.desugar_state stmts in

  (* Create a symbol table from those desugared statements *)
  let _ = Flx_symtab.add_asms state.symtab asms in

  (*
  (* Now, bind all the symbols *)
  let bbdfns = Flx_bbind.bbind state.bbind_state in
  *)
  *)

  parser_state


(* Parse stdin *)
let rec parse_stdin parser_state =
  print_string ">>> "; flush stdout;
  let parser_state =
    try
      Flx_parse.parse_channel
        ~name:"<input>"
        parser_state
        stdin;
    with
    | Dyp.Syntax_error ->
        print_endline "Syntax error";
        parse_stdin parser_state;
  in
  parser_state


let main () =
  let options = Options.make_felix_compiler_options () in
  let state = create_state options in

  (* Parse all the imported files and get the desugared statements *)
  let _, asms, local_data = parse_imports (handle_stmt state) () in

  (* Parse stdin and get the desugared statements *)
  let _, exes, _ = parse_stdin ((handle_stmt state), asms, local_data) in

  (* Now, bind all the symbols *)
  (*
  let bbdfns = Flx_bbind.bbind state.bbind_state in
  *)

  (* And print out the bound values *)
  Hashtbl.iter begin fun index (name,parent,sr,entry) ->
    print_endline (
      string_of_int index ^ " --> " ^
      Flx_print.string_of_bbdcl
        state.syms.Flx_mtypes2.dfns
        state.bbdfns
        entry
        index
    )
  end state.bbdfns;
  0
;;


exit (main ())
