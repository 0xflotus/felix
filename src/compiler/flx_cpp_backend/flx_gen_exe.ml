open List

open Flx_bbdcl
open Flx_beta
open Flx_bexe
open Flx_bexpr
open Flx_bparameter
open Flx_btype
open Flx_cexpr
open Flx_ctorgen
open Flx_ctypes
open Flx_display
open Flx_egen
open Flx_exceptions
open Flx_label
open Flx_list
open Flx_maps
open Flx_mtypes2
open Flx_name
open Flx_ogen
open Flx_options
open Flx_pgen
open Flx_print
open Flx_types
open Flx_typing
open Flx_unify
open Flx_util
open Flx_gen_helper

module CS = Flx_code_spec

(* NOTE: it isn't possible to pass an explicit tuple as a single
argument to a primitive, nor a single value of tuple/array type.
In the latter case a cast/abstraction can defeat this, for the
former you'll need to make a dummy variable.
*)



type kind_t = Function | Procedure

let gen_exe filename
  syms
  bsym_table
  (label_map, label_usage_map)
  counter
  this
  vs
  ts
  instance_no
  needs_switch
  stackable
  exe
=
  let sr = Flx_bexe.get_srcref exe in
  if length ts <> length vs then
  failwith
  (
    "[gen_exe} wrong number of args, expected vs = " ^
    si (length vs) ^
    ", got ts=" ^
    si (length ts)
  );
  let src_str = string_of_bexe bsym_table 0 exe in
  let with_comments = syms.compiler_options.with_comments in
  (*
  print_endline ("generating exe " ^ string_of_bexe bsym_table 0 exe);
  print_endline ("vs = " ^ catmap "," (fun (s,i) -> s ^ "->" ^ si i) vs);
  print_endline ("ts = " ^ catmap ","  (sbt bsym_table) ts);
  *)
  let tsub t = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts t) in
  let ge = gen_expr syms bsym_table this vs ts in
  let ge' = gen_expr' syms bsym_table this vs ts in
  let tn t = cpp_typename syms bsym_table (tsub t) in
  let bsym =
    try Flx_bsym_table.find bsym_table this with _ ->
      failwith ("[gen_exe] Can't find this " ^ string_of_bid this)
  in
  let our_display = get_display_list bsym_table this in
  let caller_name = Flx_bsym.id bsym in
  let kind = match Flx_bsym.bbdcl bsym with
    | BBDCL_fun (_,_,_,BTYP_fix 0,_) -> Procedure
    | BBDCL_fun (_,_,_,BTYP_void,_) -> Procedure
    | BBDCL_fun (_,_,_,_,_) -> Function
    | _ -> failwith "Expected executable code to be in function or procedure"
  in let our_level = length our_display in

  let rec handle_closure sr is_jump index ts subs' a stack_call =
    let index',ts' = index,ts in
    let index, ts = Flx_typeclass.fixup_typeclass_instance syms bsym_table index ts in
    if index <> index' then
      clierr sr ("[flx_gen] Virtual call of " ^ string_of_bid index' ^ " dispatches to " ^
        string_of_bid index)
    ;
    let subs =
      catmap ""
      (fun ((_,t) as e,s) ->
        let t = cpp_ltypename syms bsym_table t in
        let e = ge sr e in
        "      " ^ t ^ " " ^ s ^ " = " ^ e ^ ";\n"
      )
      subs'
    in
    let sub_start =
      if String.length subs = 0 then ""
      else "      {\n" ^ subs
    and sub_end =
      if String.length subs = 0 then ""
      else "      }\n"
    in
    let bsym =
      try Flx_bsym_table.find bsym_table index with _ ->
        failwith ("[gen_exe(call)] Can't find index " ^ string_of_bid index)
    in
    let called_name = Flx_bsym.id bsym in
    let handle_call props vs ps ret bexes =
      let is_ehandler = match ret with BTYP_fix 0 -> true | _ -> false in
      if bexes = []
      then
      "      //call to empty procedure " ^ Flx_bsym.id bsym ^ " elided\n"
      else begin
        let n = fresh_bid counter in
        let the_display =
          let d' =
            List.map begin fun (i,vslen) ->
              "ptr" ^ cpp_instance_name syms bsym_table i (list_prefix ts vslen)
            end (get_display_list bsym_table index)
          in
            if length d' > our_level
            then "this" :: tl d'
            else d'
        in
        (* if we're calling from inside a function,
           we pass a 0 continuation as the caller 'return address'
           otherwise pass 'this' as the caller 'return address'
           EXCEPT that stack calls don't pass a return address at all
        *)
        let this = match kind with
          | Function ->
            if is_jump && not is_ehandler
            then
              clierr sr ("[gen_exe] can't jump inside function " ^ caller_name ^" to " ^ called_name ^ 
               ", return type " ^ sbt bsym_table ret)
            else if stack_call then ""
            else "0"

          | Procedure ->
            if stack_call then "" else
            if is_jump then "tmp"
            else "this"
        in

        let args = match a with
          | _,BTYP_tuple [] -> this
          | _ ->
            (
              let a = ge sr a in
              if this = "" then a else this ^ ", " ^ a
            )
        in
        let name = cpp_instance_name syms bsym_table index ts in
        if mem `Cfun props then begin
          (if with_comments
          then "      //call cproc " ^ src_str ^ "\n"
          else "") ^
          "      " ^ name ^"(" ^ args ^ ");\n"
        end
        else if stack_call then begin
          (*
          print_endline ("[handle_closure] GENERATING STACK CALL for " ^ id);
          *)
          (if with_comments
          then "      //run procedure " ^ src_str ^ "\n"
          else "") ^
          "      {\n" ^
          subs ^
          "      " ^ name ^ Flx_gen_display.strd the_display props^ "\n" ^
          "      .stack_call(" ^ args ^ ");\n" ^
          "      }\n"
        end
        else
        let ptrmap = name ^ "_ptr_map" in
        begin
          match kind with
          | Function ->
            (if with_comments
            then "      //run procedure " ^ src_str ^ "\n"
            else "") ^
            "      {\n" ^
            subs ^
            "      ::flx::rtl::con_t *_p =\n" ^
            "      (FLX_NEWP(" ^ name ^ ")" ^ Flx_gen_display.strd the_display props^ ")\n" ^
            "      ->call(" ^ args ^ ");\n" ^
            "      while(_p) _p=_p->resume();\n" ^
            "      }\n"

          | Procedure ->
            let call_string =
              "      return (FLX_NEWP(" ^ name ^ ")" ^ Flx_gen_display.strd the_display props ^ ")" ^
              "\n      ->call(" ^ args ^ ");\n"
            in
            if is_jump
            then
              (if with_comments then
              "      //jump to procedure " ^ src_str ^ "\n"
              else "") ^
              "      {\n" ^
              subs ^
              "      ::flx::rtl::con_t *tmp = _caller;\n" ^
              "      _caller = 0;\n" ^
              call_string ^
              "      }\n"
            else
            (
              needs_switch := true;
              (if with_comments then
              "      //call procedure " ^ src_str ^ "\n"
              else ""
              )
              ^

              sub_start ^
              "      FLX_SET_PC(" ^ cid_of_bid n ^ ")\n" ^
              call_string ^
              sub_end ^
              "    FLX_CASE_LABEL(" ^ cid_of_bid n ^ ")\n"
            )
        end
      end
    in
    begin
    match Flx_bsym.bbdcl bsym with
    | BBDCL_external_fun (_,vs,_,BTYP_fix 0,_,_,`Code code) ->
      assert (is_jump); (* Should be a jump since doesn't return *)

      if length vs <> length ts then
      clierr sr "[gen_prim_call] Wrong number of type arguments"
      ;

      let ws s =
        let s = sc "expr" s in
        (if with_comments then "      // " ^ src_str ^ "\n" else "") ^
        sub_start ^
        "      " ^ s ^ ";\n" ^ (* NOTE added semi-colon .. hack .. *)
        sub_end
      in
      begin match code with
      | CS.Identity -> syserr sr "Identity proc is nonsense"
      | CS.Virtual ->
          clierr2 (Flx_bexe.get_srcref exe) (Flx_bsym.sr bsym) ("Instantiate virtual procedure(1) " ^ Flx_bsym.id bsym) ;
      | CS.Str s -> ws (ce_expr "expr" s)
      | CS.Str_template s ->
        let ss = gen_prim_call syms bsym_table tsub ge' s ts a (Flx_btype.btyp_none()) sr (Flx_bsym.sr bsym) "atom"  in
        ws ss
      end

    | BBDCL_external_fun (_,vs,_,BTYP_void,_,_,`Code code) ->
      assert (not is_jump);

      if length vs <> length ts then
      clierr sr "[gen_prim_call] Wrong number of type arguments"
      ;

      let ws s =
        let s = sc "expr" s in
        (if with_comments then "      // " ^ src_str ^ "\n" else "") ^
        sub_start ^
        "      " ^ s ^ "\n" ^
        sub_end
      in
      begin match code with
      | CS.Identity -> syserr sr "Identity proc is nonsense"
      | CS.Virtual ->
          clierr2 (Flx_bexe.get_srcref exe) (Flx_bsym.sr bsym) ("Instantiate virtual procedure(1) " ^ Flx_bsym.id bsym) ;
      | CS.Str s -> ws (ce_expr "expr" s)
      | CS.Str_template s ->
        let ss = gen_prim_call syms bsym_table tsub ge' s ts a (Flx_btype.btyp_none()) sr (Flx_bsym.sr bsym) "atom"  in
        ws ss
      end

    | BBDCL_external_fun (_,vs,ps_cf,ret,_,_,`Callback _) ->
      assert (not is_jump);
      assert (ret = btyp_void ());

      if length vs <> length ts then
      clierr sr "[gen_prim_call] Wrong number of type arguments"
      ;
      let s = Flx_bsym.id bsym ^ "($a);" in
      let s =
        gen_prim_call syms bsym_table tsub ge' s ts a (Flx_btype.btyp_none()) sr (Flx_bsym.sr bsym) "atom"
      in
      let s = sc "expr" s in
      (if with_comments then "      // " ^ src_str ^ "\n" else "") ^
      sub_start ^
      "      " ^ s ^ "\n" ^
      sub_end


    | BBDCL_fun (props,vs,ps,ret,bexes) ->
      begin match ret with
      | BTYP_void 
      | BTYP_fix 0 -> handle_call props vs ps ret bexes
      | _ ->
        failwith
        (
          "[gen_exe] Expected '" ^ Flx_bsym.id bsym ^ "' to be procedure constant, got function " ^
          string_of_bbdcl bsym_table (Flx_bsym.bbdcl bsym) index
        )
      end
    | _ ->
      failwith
      (
        "[gen_exe] Expected '" ^ Flx_bsym.id bsym ^ "' to be procedure constant, got " ^
        string_of_bbdcl bsym_table (Flx_bsym.bbdcl bsym) index
      )
    end
  in
  let gen_nonlocal_goto pc frame s =
    (* WHAT THIS CODE DOES: we pop the call stack until
       we find the first ancestor containing the target label,
       set the pc there, and return its continuation to the
       driver; we know the address of this frame because
       it must be in this function's display.
    *)
    let target_instance =
      try Hashtbl.find syms.instances (frame, ts)
      with Not_found -> failwith "Woops, bugged code, wrong type arguments for instance?"
    in
    let frame_ptr = "ptr" ^ cpp_instance_name syms bsym_table frame ts in
    "      // non local goto " ^ cid_of_flxid s ^ "\n" ^
    "      {\n" ^
    "        ::flx::rtl::con_t *tmp1 = this;\n" ^
    "        while(tmp1 && " ^ frame_ptr ^ "!= tmp1)\n" ^
    "        {\n" ^
    "          ::flx::rtl::con_t *tmp2 = tmp1->_caller;\n" ^
    "          tmp1 -> _caller = 0;\n" ^
    "          tmp1 = tmp2;\n" ^
    "        }\n" ^
    "      }\n" ^
    "      " ^ frame_ptr ^ "->pc = FLX_FARTARGET(" ^ cid_of_bid pc ^ "," ^ cid_of_bid target_instance ^ "," ^ s ^ ");\n" ^
    "      return " ^ frame_ptr ^ ";\n"
  in
  let forget_template sr s = match s with
  | CS.Identity -> syserr sr "Identity proc is nonsense(2)!"
  | CS.Virtual -> clierr sr "Instantiate virtual procedure(2)!"
  | CS.Str s -> s
  | CS.Str_template s -> s
  in
  let rec gexe exe =
    (*
    print_endline (string_of_bexe bsym_table 0 exe);
    *)
    match exe with
    | BEXE_try _ -> "  try {\n";
    | BEXE_endtry _ -> "  }\n";
    | BEXE_catch (sr, s, t) -> "\n}\n  catch (" ^tn t^ " &" ^s^") {\n";

    | BEXE_axiom_check _ -> assert false
    | BEXE_code (sr,s) -> forget_template sr s
    | BEXE_nonreturn_code (sr,s) -> forget_template sr s
    | BEXE_comment (_,s) -> "/*" ^ s ^ "*/\n"
    | BEXE_label (_,s) ->
      let local_labels =
        try Hashtbl.find label_map this with _ ->
          failwith ("[gen_exe] Can't find label map of " ^ string_of_bid this)
      in
      let label_index =
        try Hashtbl.find local_labels s
        with _ -> failwith ("[gen_exe] In " ^ Flx_bsym.id bsym ^ ": Can't find label " ^ cid_of_flxid s)
      in
      let label_kind = get_label_kind_from_index label_usage_map label_index in
      (match kind with
        | Procedure ->
          begin match label_kind with
          | `Far ->
            needs_switch := true;
            "    FLX_LABEL(" ^ cid_of_bid label_index ^ "," ^
              cid_of_bid instance_no ^ "," ^ cid_of_flxid s ^ ")\n"
          | `Near ->
            "    " ^ cid_of_flxid s ^ ":;\n"
          | `Unused -> ""
          end

        | Function ->
          begin match label_kind with
          | `Far -> failwith ("[gen_exe] In function " ^ Flx_bsym.id bsym ^ 
              ": Non-local going to label " ^s)
          | `Near ->
            "    " ^ cid_of_flxid s ^ ":;\n"
          | `Unused -> ""
          end
      )

    (* FIX THIS TO PUT SOURCE REFERENCE IN *)
    | BEXE_halt (sr,msg) ->
      let msg = Flx_print.string_of_string ("HALT: " ^ msg) in
      let f, sl, sc, el, ec = Flx_srcref.to_tuple sr in
      let s = Flx_print.string_of_string f ^"," ^
        si sl ^ "," ^ si sc ^ "," ^
        si el ^ "," ^ si ec
      in
       "      FLX_HALT(" ^ s ^ "," ^ msg ^ ");\n"

    | BEXE_trace (sr,v,msg) ->
      let msg = Flx_print.string_of_string ("TRACE: " ^ msg) in
      let f, sl, sc, el, ec = Flx_srcref.to_tuple sr in
      let s = Flx_print.string_of_string f ^"," ^
        si sl ^ "," ^ si sc ^ "," ^
        si el ^ "," ^ si ec
      in
       "      FLX_TRACE(" ^ v ^"," ^ s ^ "," ^ msg ^ ");\n"


    | BEXE_goto (sr,s) ->
      begin match find_label bsym_table label_map this s with
      | `Local _ -> "      goto " ^ cid_of_flxid s ^ ";\n"
      | `Nonlocal (pc,frame) -> gen_nonlocal_goto pc frame s
      | `Unreachable ->
        print_endline "LABELS ..";
        let labels = Hashtbl.find label_map this in
        Hashtbl.iter (fun lab lno ->
          print_endline ("Label " ^ lab ^ " -> " ^ string_of_bid lno);
        )
        labels
        ;
        clierr sr ("Unconditional Jump to unreachable label " ^ cid_of_flxid s)
      end

    | BEXE_ifgoto (sr,e,s) ->
      begin match find_label bsym_table label_map this s with
      | `Local _ ->
        "      if(" ^ ge sr e ^ ") goto " ^ cid_of_flxid s ^ ";\n"
      | `Nonlocal (pc,frame) ->
        let skip = "_" ^ cid_of_bid (fresh_bid syms.counter) in
        let not_e = ce_prefix "!" (ge' sr e) in
        let not_e = string_of_cexpr not_e in
        "      if("^not_e^") goto " ^ cid_of_flxid skip ^ ";\n"  ^
        gen_nonlocal_goto pc frame s ^
        "    " ^ cid_of_flxid skip ^ ":;\n"

      | `Unreachable ->
        clierr sr ("Conditional Jump to unreachable label " ^ s)
      end

    (* Hmmm .. stack calls ?? *)
    | BEXE_call_stack (sr,index,ts,a)  ->
      let bsym =
        try Flx_bsym_table.find bsym_table index with _ ->
          failwith ("[gen_expr(apply instance)] Can't find index " ^
            string_of_bid index)
      in
      let ge_arg ((x,t) as a) =
        let t = tsub t in
        match t with
        | BTYP_tuple [] -> ""
        | _ -> ge sr a
      in
      let nth_type ts i = match ts with
        | BTYP_tuple ts -> nth ts i
        | BTYP_array (t,BTYP_unitsum n) -> assert (i<n); t
        | _ -> assert false
      in
      begin match Flx_bsym.bbdcl bsym with
      | BBDCL_fun (props,vs,(ps,traint),BTYP_fix 0,_)
      | BBDCL_fun (props,vs,(ps,traint),BTYP_void,_) ->
        assert (mem `Stack_closure props);
        let a = match a with (a,t) -> a, tsub t in
        let ts = List.map tsub ts in
        (* C FUNCTION CALL *)
        if mem `Cfun props || mem `Pure props && not (mem `Heap_closure props) then
          let display = get_display_list bsym_table index in
          let name = cpp_instance_name syms bsym_table index ts in
          let s =
            assert (length display = 0);
            match ps with
            | [] -> ""
            | [{pindex=i; ptyp=t}] ->
              if Hashtbl.mem syms.instances (i,ts)
              && not (t = btyp_tuple [])
              then
                ge_arg a
              else ""

            | _ ->
              begin match a with
              | BEXPR_tuple xs,_ ->
                (*
                print_endline ("Arg to C function is tuple " ^ sbe a);
                *)
                fold_left
                (fun s (((x,t) as xt),{pindex=i}) ->
                  let x =
                    if Hashtbl.mem syms.instances (i,ts)
                    && not (t = btyp_tuple [])
                    then ge_arg xt
                    else ""
                  in
                  if String.length x = 0 then s else
                  s ^
                  (if String.length s > 0 then ", " else "") ^ (* append a comma if needed *)
                  x
                )
                ""
                (combine xs ps)

              | _,tt ->
                let tt = beta_reduce syms.Flx_mtypes2.counter bsym_table sr (tsubst vs ts tt) in
                (* NASTY, EVALUATES EXPR MANY TIMES .. *)
                let n = ref 0 in
                fold_left
                (fun s (i,{pindex=j;ptyp=t}) ->
                  (*
                  print_endline ( "ps = " ^ catmap "," (fun (id,(p,t)) -> id) ps);
                  print_endline ("tt=" ^ sbt bsym_table tt);
                  *)
                  let t = nth_type tt i in
                  let a' = bexpr_get_n t (i,a) in
                  let x =
                    if Hashtbl.mem syms.instances (j,ts)
                    && not (t = btyp_tuple [])
                    then ge_arg a'
                    else ""
                  in
                  incr n;
                  if String.length x = 0 then s else
                  s ^ (if String.length s > 0 then ", " else "") ^ x
                )
                ""
                (combine (nlist (length ps)) ps)
              end
          in
          let s =
            if mem `Requires_ptf props then
              if String.length s > 0 then "FLX_FPAR_PASS " ^ s
              else "FLX_FPAR_PASS_ONLY"
            else s
          in
            "  " ^ name ^ "(" ^ s ^ ");\n"
        else
          let subs,x = Flx_unravel.unravel syms bsym_table a in
          let subs = List.map
            (fun ((e,t),s) -> (e,tsub t), cid_of_flxid s)
            subs
          in
          handle_closure sr false index ts subs x true
      | _ -> failwith "procedure expected"
      end


    | BEXE_call_prim (sr,index,ts,a)
    | BEXE_call_direct (sr,index,ts,a)
    | BEXE_call (sr,(BEXPR_closure (index,ts),_),a) ->
      let a = match a with (a,t) -> a, tsub t in
      let subs,x = Flx_unravel.unravel syms bsym_table a in
      let subs = List.map (fun ((e,t),s) -> (e,tsub t), cid_of_flxid s) subs in
      let ts = List.map tsub ts in
      handle_closure sr false index ts subs x false

    (* i1: variable
       i2, class_ts: class closure
       i3: constructor
       a: ctor argument
    *)
    | BEXE_jump (sr,((BEXPR_closure (index,ts),_)),a)
    | BEXE_jump_direct (sr,index,ts,a) ->
      let a = match a with (a,t) -> a, tsub t in
      let subs,x = Flx_unravel.unravel syms bsym_table a in
      let subs = List.map (fun ((e,t),s) -> (e,tsub t), cid_of_flxid s) subs in
      let ts = List.map tsub ts in
      handle_closure sr true index ts subs x false

    (* If p is a variable containing a closure,
       and p recursively invokes the same closure,
       then the program counter and other state
       of the closure would be lost, so we clone it
       instead .. the closure variables is never
       used (a waste if it isn't re-entered .. oh well)
     *)

    | BEXE_call (sr,p,a) ->
      let args =
        let this = match kind with
          | Procedure -> "this"
          | Function -> "0"
        in
        match a with
        | _,BTYP_tuple [] -> this
        | _ -> this ^ ", " ^ ge sr a
      in
      begin let _,t = p in match t with
      | BTYP_cfunction (d,_) ->
        begin match d with
        | BTYP_tuple ts ->
          begin match a with
          | BEXPR_tuple xs,_ ->
            let s = String.concat ", " (List.map (fun x -> ge sr x) xs) in
            (ge sr p) ^"(" ^ s ^ ");\n"
          | _ ->
           failwith "[flx_gen_exe][tuple] can't split up arg to C function yet"
          end
        | BTYP_array (t,BTYP_unitsum n) ->
          let ts = 
           let rec aux ts n = if n = 0 then ts else aux (t::ts) (n-1) in
           aux [] n
          in
          begin match a with
          | BEXPR_tuple xs,_ ->
            let s = String.concat ", " (List.map (fun x -> ge sr x) xs) in
            (ge sr p) ^"(" ^ s ^ ");\n"
          | _ ->
            failwith "[flx_gen_exe][array] can't split up arg to C function yet"
          end

        | _ ->
          (ge sr p) ^"(" ^ ge sr a ^ ");\n"
        end
      | _ ->
      match kind with
      | Function ->
        (if with_comments then
        "      //run procedure " ^ src_str ^ "\n"
        else "") ^
        "      {\n" ^
        "        ::flx::rtl::con_t *_p = ("^ge sr p ^ ")->clone()\n      ->call("^args^");\n" ^
        "        while(_p) _p=_p->resume();\n" ^
        "      }\n"



      | Procedure ->
        needs_switch := true;
        let n = fresh_bid counter in
        (if with_comments then
        "      //"^ src_str ^ "\n"
        else "") ^
        "      FLX_SET_PC(" ^ cid_of_bid n ^ ")\n" ^
        "      return (" ^ ge sr p ^ ")->clone()\n      ->call(" ^ args ^");\n" ^
        "    FLX_CASE_LABEL(" ^ cid_of_bid n ^ ")\n"
      end

    | BEXE_jump (sr,p,a) ->
      let args = match a with
        | _,BTYP_tuple [] -> "tmp"
        | _ -> "tmp, " ^ ge sr a
      in
      begin let _,t = p in match t with
      | BTYP_cfunction _ ->
        "    "^ge sr p ^ "("^ge sr a^");\n"
      | _ ->
      (if with_comments then
      "      //"^ src_str ^ "\n"
      else "") ^
      "      {\n" ^
      "        ::flx::rtl::con_t *tmp = _caller;\n" ^
      "        _caller=0;\n" ^
      "        return (" ^ ge sr p ^ ")\n      ->call(" ^ args ^");\n" ^
      "      }\n"
      end

    | BEXE_proc_return _ ->
      begin match kind with
      | Procedure ->
        if stackable then
        "      return;\n"
        else
        "      FLX_RETURN // procedure return\n"
      | Function ->
        clierr sr "Function contains procedure return";
      end

    | BEXE_svc (sr,index) ->
      let bsym =
        try Flx_bsym_table.find bsym_table index with _ ->
          failwith ("[gen_expr(name)] Can't find index " ^ string_of_bid index)
      in
      let t =
        match Flx_bsym.bbdcl bsym with
        | BBDCL_val (_,t,(`Val | `Var)) -> t
        | _ -> syserr (Flx_bsym.sr bsym) "Expected read argument to be variable"
      in
      let n = fresh_bid counter in
      needs_switch := true;
      "      //read variable\n" ^
      "      p_svc = &" ^ get_var_ref syms bsym_table this index ts^";\n" ^
      "      FLX_SET_PC(" ^ cid_of_bid n ^ ")\n" ^
      "      return this;\n" ^
      "    FLX_CASE_LABEL(" ^ cid_of_bid n ^ ")\n"


    | BEXE_yield (sr,e) ->
      let labno = fresh_bid counter in
      let code =
        "      FLX_SET_PC(" ^ cid_of_bid labno ^ ")\n" ^
        (
          let _,t = e in
          (if with_comments then
          "      //" ^ src_str ^ ": type "^tn t^"\n"
          else "") ^
          "      return "^ge sr e^";\n"
        )
        ^
        "    FLX_CASE_LABEL(" ^ cid_of_bid labno ^ ")\n"
      in
      needs_switch := true;
      code

    | BEXE_fun_return (sr,e) ->
      let _,t = e in
      (if with_comments then
      "      //" ^ src_str ^ ": type "^tn t^"\n"
      else "") ^
      (* HACK WARNING! *)
      begin match t with
      | BTYP_fix 0 -> "      "^ge sr e^"; // non-returning\n"
      | _ ->          "      return "^ge sr e^";\n"
      end

    | BEXE_nop (_,s) -> "      //Nop: " ^ s ^ "\n"

    | BEXE_assign (sr,e1,(( _,t) as e2)) ->
      let t = tsub t in
      begin match t with
      | BTYP_tuple [] -> ""
      | _ ->
      (if with_comments then "      //"^src_str^"\n" else "") ^
      "      "^ ge sr e1 ^ " = " ^ ge sr e2 ^
      ";\n"
      end

    | BEXE_init (sr,v,((_,t) as e)) ->
      let t = tsub t in
      begin match t with
      | BTYP_tuple [] -> ""
      | _ ->
        let bsym =
          try Flx_bsym_table.find bsym_table v with Not_found ->
            failwith ("[gen_exe] can't find index " ^ string_of_bid v)
        in
        begin match Flx_bsym.bbdcl bsym with
        | BBDCL_val (_,_,kind) ->
            (if with_comments then "      //"^src_str^"\n" else "") ^
            "      " ^
            begin match kind with
            | `Tmp -> get_variable_typename syms bsym_table v [] ^ " "
            | _ -> ""
            end ^
            get_ref_ref syms bsym_table this v ts ^
            " " ^
            " = " ^
            ge sr e ^
            ";\n"
          | _ -> assert false
        end
      end

    | BEXE_begin -> "      {\n"
    | BEXE_end -> "      }\n"

    | BEXE_assert (sr,e) ->
       let f, sl, sc, el, ec = Flx_srcref.to_tuple sr in
       let s = string_of_string f ^ "," ^
         si sl ^ "," ^ si sc ^ "," ^
         si el ^ "," ^ si ec
       in
       "      {if(FLX_UNLIKELY(!(" ^ ge sr e ^ ")))\n" ^
       "        FLX_ASSERT_FAILURE("^s^");}\n"

    | BEXE_assert2 (sr,sr2,e1,e2) ->
       print_endline "ASSERT2";
       let f, sl, sc, el, ec = Flx_srcref.to_tuple sr in
       let s = string_of_string f ^ "," ^
         si sl ^ "," ^ si sc ^ "," ^
         si el ^ "," ^ si ec
       in
       let f2, sl2, sc2, el2, ec2 = Flx_srcref.to_tuple sr2 in
       let s2 = string_of_string f2 ^ "," ^
         si sl2 ^ "," ^ si sc2 ^ "," ^
         si el2 ^ "," ^ si ec2
       in
       (match e1 with
       | None ->
       "      {if(FLX_UNLIKELY(!(" ^ ge sr e2 ^ ")))\n"
       | Some e ->
       "      {if(FLX_UNLIKELY("^ge sr e^" && !(" ^ ge sr e2 ^ ")))\n"
       )
       ^
       "        FLX_ASSERT2_FAILURE("^s^"," ^ s2 ^");}\n"

    | BEXE_axiom_check2 (sr,sr2,e1,e2) ->
       (*
       print_endline "AXIOM CHECK";
       *)
       let f, sl, sc, el, ec = Flx_srcref.to_tuple sr in
       let s = string_of_string f ^ "," ^
         si sl ^ "," ^ si sc ^ "," ^
         si el ^ "," ^ si ec
       in
       let f2, sl2, sc2, el2, ec2 = Flx_srcref.to_tuple sr2 in
       let s2 = string_of_string f2 ^ "," ^
         si sl2 ^ "," ^ si sc2 ^ "," ^
         si el2 ^ "," ^ si ec2
       in
       try
       (match e1 with
       | None ->
       "      {if(FLX_UNLIKELY(!(" ^ ge sr e2 ^ ")))\n"
       | Some e ->
       "      {if(FLX_UNLIKELY("^ge sr e^" && !(" ^ ge sr e2 ^ ")))\n"
       )
       ^
       "        FLX_AXIOM_CHECK_FAILURE("^s^"," ^ s2 ^");}\n"
       with _ ->
         print_endline "ELIDING FAULTY AXIOM CHECK -- typeclass virtual instantiation failure?";
         ""


  in gexe exe

let gen_exes
  filename
  syms
  bsym_table
  display
  label_info
  counter
  index
  exes
  vs
  ts
  instance_no
  stackable
=
  let needs_switch = ref false in
  let s = cat ""
    (List.map (gen_exe
      filename
      syms
      bsym_table
      label_info
      counter
      index
      vs
      ts
      instance_no
      needs_switch
      stackable)
    exes)
  in
  s,!needs_switch


