(** PRINTER STATE *)

type state = {
  debug: bool;
  ignored: Params.t;
}

let initial = {
  debug = true;
  ignored = Params.empty;
}

let rec pair_up_ty ~loc ty1 ty2 pairs =
  let ty1 = Constraints.expand_ty ty1
  and ty2 = Constraints.expand_ty ty2 in
  match ty1, ty2 with

  | (ty1, ty2) when ty1 = ty2 -> pairs

  | (Type.Param t1, Type.Param t2) ->
    let (ts, ds, rs) = pairs in
    ((t1, t2) :: ts, ds, rs)

  | (Type.Arrow (ty1, drty1), Type.Arrow (ty2, drty2)) ->
    pair_up_ty ~loc ty2 ty1 (pair_up_dirty ~loc drty1 drty2 pairs)

  | (Type.Tuple tys1, Type.Tuple tys2) ->
    assert (List.length tys1 = List.length tys2);
    List.fold_right2 (pair_up_ty ~loc) tys1 tys2 pairs

  | (Type.Apply (ty_name1, args1), Type.Apply (ty_name2, args2)) ->
    assert (ty_name1 = ty_name2);
    begin match Tctx.lookup_params ty_name1 with
      | None -> Error.typing ~loc "Undefined type %s" ty_name1
      | Some params -> pair_up_args ~loc params args1 args2 pairs
    end

  (* The following two cases cannot be merged into one, as the whole matching
     fails if both types are Apply, but only the second one is transparent. *)
  | (Type.Apply (ty_name, args), ty) when Tctx.transparent ~loc ty_name ->
    begin match Tctx.ty_apply ~loc ty_name args with
      | Tctx.Inline ty' -> pair_up_ty ~loc ty' ty pairs
      | Tctx.Sum _ | Tctx.Record _ -> assert false (* None of these are transparent *)
    end

  | (ty, Type.Apply (ty_name, args)) when Tctx.transparent ~loc ty_name ->
    begin match Tctx.ty_apply ~loc ty_name args with
      | Tctx.Inline ty' -> pair_up_ty ~loc ty ty' pairs
      | Tctx.Sum _ | Tctx.Record _ -> assert false (* None of these are transparent *)
    end

  | (Type.Handler (drty_in1, drty_out1), Type.Handler (drty_in2, drty_out2)) ->
    pair_up_dirty ~loc drty_in2 drty_in1 (pair_up_dirty ~loc drty_out1 drty_out2 pairs)

  | (ty1, ty2) ->
    Print.debug "%t <<>> %t" (Type.print_ty ty1) (Type.print_ty ty2);
    assert false

and pair_up_args ~loc (ts, ds, rs) (tys1, drts1, rs1) (tys2, drts2, rs2) pairs =
  (* NB: it is assumed here that
     List.length tys1 = List.length tys2 && List.length drts1 = List.length drts2 && List.length rgns1 = List.length rgns2 *)
  let for_parameters add ps lst1 lst2 pairs =
    List.fold_right2 (fun (_, (cov, contra)) (ty1, ty2) pairs ->
        let pairs = if cov then add ty1 ty2 pairs else pairs in
        if contra then add ty2 ty1 pairs else pairs) ps (List.combine lst1 lst2) pairs
  in
  let pairs = for_parameters (pair_up_ty ~loc) ts tys1 tys2 pairs in
  let pairs = for_parameters (pair_up_dirt) ds drts1 drts2 pairs in
  for_parameters (fun r1 r2 (ts, ds, rs) -> (ts, ds, (r1, r2) :: rs)) rs rs1 rs2 pairs

and pair_up_dirty ~loc (ty1, drt1) (ty2, drt2) pairs =
  pair_up_ty ~loc ty1 ty2 (pair_up_dirt drt1 drt2 pairs)

and pair_up_dirt drt1 drt2 (ts, ds, rs) =
  let {Type.ops = ops1; Type.rest = rest1} = Constraints.expand_dirt drt1
  and {Type.ops = ops2; Type.rest = rest2} = Constraints.expand_dirt drt2 in
  let op_less (op, dt1) (ts, ds, rs) =
    begin match Common.lookup op ops2 with
      | Some dt2 -> (ts, ds, (dt1, dt2) :: rs)
      | None -> (ts, ds, rs)
    end
  in
  List.fold_right op_less ops1 (ts, (rest1, rest2) :: ds, rs)

let safely_ignored (ts, ds, rs) constraints =
  let ignored = Params.empty in
  let ignored = List.fold_right (fun (t1, t2) ignored ->
      if Constraints.pure_ty_param t2 constraints then Params.add_ty_param t1 ignored else ignored
    ) ts ignored in
  let ignored = List.fold_right (fun (d1, d2) ignored ->
      if Constraints.pure_dirt_param d2 constraints then Params.add_dirt_param d1 ignored else ignored
    ) ds ignored in
  let ignored = List.fold_right (fun (r1, r2) ignored ->
      if Constraints.pure_region_param r2 constraints then Params.add_region_param r1 ignored else ignored
    ) rs ignored in
  ignored

let determine_pure_recursive_functions st defs =
  let fold (x, ({Typed.term = (_, c)} as a)) st =
    let c_ctx, _, _ = c.Typed.scheme in
    match Common.lookup x c_ctx with
    | Some in_ty ->
      let (_, (a_in, a_out), constraints) = a.Typed.scheme in
      let out_ty = Type.Arrow (a_in, a_out) in
      let pairs = pair_up_ty ~loc:a.Typed.location in_ty out_ty ([], [], []) in
      let ignored = safely_ignored pairs constraints in
      {st with ignored = Params.append ignored st.ignored}
    | None -> 
      st
  in
  List.fold_right fold defs st


(** TYPES *)


let rec print_type ?max_level ty ppf =
  let print ?at_level = Print.print ?max_level ?at_level ppf in
  match ty with
  | Type.Apply ("empty", _) ->
    print "unit"
  | Type.Apply (ty_name, args) ->
    print ~at_level:1 "%t %s" (print_args args) ty_name
  | Type.Param p ->
    print "%t" (Params.print_type_param p)
  | Type.Basic t ->
    print "(%s)" t
  | Type.Tuple tys ->
    print ~at_level:1 "(%t)" (Print.sequence "*" print_type tys)
  | Type.Arrow (ty, drty) ->
    print ~at_level:2 "(%t -> %t)" (print_type ~max_level:1 ty) (print_dirty_type drty)
  | Type.Handler ((ty1, _), (ty2, _)) ->
    print ~at_level:2 "(%t, ???, %t) handler" (print_type ty1) (print_type ty2)

and print_dirty_type (ty, drt) ppf =
  Format.fprintf ppf "_"

and print_args (tys, _, _) ppf =
  match tys with
  | [] -> ()
  | _ -> Format.fprintf ppf "(%t)" (Print.sequence "," print_type tys)


(** TYPE DEFINITIONS *)

let rec print_params params ppf =
  match Params.project_ty_params params with
  | [] -> ()
  | tys -> Format.fprintf ppf "(%t)" (Print.sequence "," Params.print_type_param tys)

let print_tydef_body ty_def ppf =
  match ty_def with
  | Tctx.Record flds ->
    let print_field (fld, ty) ppf = Format.fprintf ppf "%s: %t" fld (print_type ty) in
    Format.fprintf ppf "{@[<hov>%t@]}" (Print.sequence "; " print_field flds)
  | Tctx.Sum variants ->
    let print_variant (lbl, ty) ppf =
      match ty with
      | None -> Format.fprintf ppf "%s" lbl
      | Some ty -> Format.fprintf ppf "%s of %t" lbl (print_type ~max_level:0 ty)
    in
    Format.fprintf ppf "@[<hov>%t@]" (Print.sequence "|" print_variant variants)
  | Tctx.Inline ty -> print_type ty ppf

let print_tydef (name, (params, body)) ppf =
  Format.fprintf ppf "%t %s = %t" (print_params params) name (print_tydef_body body)

let print_tydefs tydefs ppf =
  Format.fprintf ppf "type %t" (Print.sequence "\nand\n" print_tydef tydefs)


(** SYNTAX *)

let print_variable = Typed.Variable.print


let print_effect (eff, _) ppf = Print.print ppf "Effect_%s" eff

let print_effect_region (eff, (region)) ppf = Print.print ppf "Effect_%s -> %t" eff (Params.print_region_param region)

let rec print_pattern ?max_level p ppf =
  let print ?at_level = Print.print ?max_level ?at_level ppf in
  match p.Typed.term with
  | Typed.PVar x ->
    print "%t" (print_variable x)
  | Typed.PAs (p, x) ->
    print "%t as %t" (print_pattern p) (print_variable x)
  | Typed.PConst c ->
    Const.print c ppf
  | Typed.PTuple lst ->
    Print.tuple print_pattern lst ppf
  | Typed.PRecord lst ->
    Print.record print_pattern lst ppf
  | Typed.PVariant (lbl, None) when lbl = Common.nil ->
    print "[]"
  | Typed.PVariant (lbl, None) ->
    print "%s" lbl
  | Typed.PVariant ("(::)", Some ({ Typed.term = Typed.PTuple [p1; p2] })) ->
    print ~at_level:1 "((%t) :: (%t))" (print_pattern p1) (print_pattern p2)
  | Typed.PVariant (lbl, Some p) ->
    print ~at_level:1 "(%s @[<hov>%t@])" lbl (print_pattern p)
  | Typed.PNonbinding ->
    print "_"

let compute_ignored st (ctx, _, cstrs) =
  (* let (_, ds, rs) = st.ignored in *)
  (* Print.debug "ignored dirt param: %t" (Print.sequence "," Type.print_dirt_param ds); *)
  (* Print.debug "ignored region param: %t" (Print.sequence "," Type.print_region_param rs); *)
  st.ignored

let is_pure_function st e =
  let ignored = compute_ignored st e.Typed.scheme in
  Scheme.is_pure_function_type ~loc:e.Typed.location ignored e.Typed.scheme

let is_pure_abstraction st {Typed.term = (_, c)} =
  let ignored = compute_ignored st c.Typed.scheme in
  Scheme.is_pure ignored c.Typed.scheme

let is_pure_handler st e =
  false

let rec print_expression ?max_level st e ppf =
  let print ?at_level = Print.print ?max_level ?at_level ppf in
  match e.Typed.term with
  | Typed.Var x ->
    print "%t" (print_variable x)
  | Typed.BuiltIn s ->
    print "%s" s
  | Typed.Const c ->
    print "%t" (Const.print c)
  | Typed.Tuple lst ->
    Print.tuple (print_expression st) lst ppf
  | Typed.Record lst ->
    Print.record (print_expression st) lst ppf
  | Typed.Variant (lbl, None) ->
    print "%s" lbl
  | Typed.Variant (lbl, Some e) ->
    print ~at_level:1 "(%s %t)" lbl (print_expression st e)
  | Typed.Lambda a ->
    let pure = is_pure_function st e in
    print ~at_level:2 "fun %t" (print_abstraction ~pure st a)
  | Typed.Handler h ->
    let pure = is_pure_handler st e in
    print "%t" (print_handler ~pure st h)
  | Typed.Effect eff ->
    print ~at_level:2 "effect %t" (print_effect eff)
  | Typed.Pure c ->
    print_computation ?max_level ~pure:true st c ppf

and print_function_argument ?max_level st e ppf =
  let print ?at_level = Print.print ?max_level ?at_level ppf in
  if is_pure_function st e then
    print "(fun x -> value (%t x))" (print_expression ~max_level:1 st e)
  else
    print_expression ~max_level:0 st e ppf

and print_computation ?max_level ~pure st c ppf =
  let ignored = compute_ignored st c.Typed.scheme in
  let is_pure_computation = Scheme.is_pure ~loc:c.Typed.location ignored c.Typed.scheme in
  let expect_pure_computation = pure in
  (*   let ignored = 
       if pure then
        let params = Scheme.present_in_abstraction a.Typed.scheme in
        Params.append params st.ignored
       else
        st.ignored
       in
       (* *)  let (_, _, cstrs) = a.Typed.scheme in *)
  (* let st = {st with ignored = Constraints.add_prec cstrs ignored} in *)
  if st.debug then
    Print.debug ~loc:c.Typed.location "%t@.expect: %b, is: %b@.BEGIN@.%t@.END"
      (Scheme.print_dirty_scheme c.Typed.scheme)
      expect_pure_computation
      is_pure_computation
      (Typed.print_computation c);
  match expect_pure_computation, is_pure_computation with
  | true, true ->
    print_computation' ?max_level ~pure:true st c ppf
  | true, false ->
    Print.print ?max_level ppf "run %t" (print_computation' ~max_level:0 ~pure:false st c)
  | false, true ->
    Print.print ?max_level ppf "value %t" (print_computation' ~max_level:0 ~pure:true st c)
  | false, false ->
    print_computation' ?max_level ~pure:false st c ppf
and print_computation' ?max_level ~pure st c ppf =
  let print ?at_level = Print.print ?max_level ?at_level ppf in
  match c.Typed.term with
  | Typed.Apply (e1, e2) ->
    print ~at_level:1 "%t@ %t"
      (print_expression ~max_level:1 st e1)
      (print_function_argument ~max_level:0 st e2)
  | Typed.Value e ->
    (* assert pure; *)
    print ~at_level:1 "%t" (print_expression ~max_level:0 st e)
  | Typed.Match (e, []) ->
    print ~at_level:2 "(match %t with _ -> assert false)"
      (print_expression st e)
  | Typed.Match (e, lst) ->
    print ~at_level:2 "(match %t with @[<v>| %t@])"
      (print_expression st e)
      (Print.cases (print_abstraction ~pure st) lst)
  | Typed.Handle (e, c) ->
    print ~at_level:1 "handle %t %t"
      (print_expression ~max_level:0 st e)
      (print_computation ~max_level:0 ~pure:false st c)
  | Typed.Let (lst, c) ->
    print ~at_level:2 "%t" (print_multiple_bind ~pure st (lst, c))
  | Typed.LetRec (lst, c) ->
    let st = determine_pure_recursive_functions st lst in
    print ~at_level:2 "let rec @[<hov>%t@] in %t"
      (Print.sequence " and " (print_let_rec_abstraction st) lst) (print_computation ~pure st c)
  | Typed.Call (eff, e, a) ->
    assert (not pure);
    print ~at_level:1 "call %t %t (@[fun %t@])"
      (print_effect eff) (print_expression ~max_level:0 st e) (print_abstraction ~pure st a)
  | Typed.Bind (c1, {Typed.term = (p, c2)}) when pure ->
    print ~at_level:2 "let @[<hov>%t =@ %t@ in@]@ %t"
      (print_pattern p)
      (print_computation ~max_level:0 ~pure st c1)
      (print_computation ~pure st c2)
  | Typed.Bind (c1, a) ->
    print ~at_level:2 "@[<hov>%t@ >>@ @[fun %t@]@]"
      (print_computation ~max_level:0 ~pure st c1)
      (print_abstraction ~pure st a)
  | Typed.LetIn (e, {Typed.term = (p, c)}) ->
    print ~at_level:2 "let @[<hov>%t =@ %t@ in@]@ %t"
      (print_pattern p)
      (print_expression st e)
      (print_computation ~pure st c)

and print_handler ~pure st h ppf =
  Print.print ppf
    "{@[<hov>
      value_clause = (@[fun %t@]);@ 
      finally_clause = (@[fun %t@]);@ 
      effect_clauses = (fun (type a) (type b) (x : (a, b) effect) ->
        ((match x with %t) : a -> (b -> _ computation) -> _ computation))
    @]}"
    (print_abstraction ~pure st h.Typed.value_clause)
    (print_abstraction ~pure st h.Typed.finally_clause)
    (print_effect_clauses ~pure st h.Typed.effect_clauses)

and print_effect_clauses ~pure st eff_clauses ppf =
  let print ?at_level = Print.print ?at_level ppf in
  match eff_clauses with
  | [] ->
    print "| eff' -> fun arg k -> Call (eff', arg, k)"
  | (((_, (t1, t2)) as eff), {Typed.term = (p1, p2, c)}) :: cases ->
    print ~at_level:1
      "| %t -> (fun (%t : %t) (%t : %t -> _ computation) -> %t) %t"
      (print_effect eff)
      (print_pattern p1) (print_type t1)
      (print_pattern p2) (print_type t2)
      (print_computation ~pure st c)
      (print_effect_clauses ~pure st cases)

and print_abstraction ~pure st {Typed.term = (p, c)} ppf =
  Format.fprintf ppf "%t ->@;<1 2> %t" (print_pattern p) (print_computation ~pure st c)

and print_multiple_bind ~pure st (lst, c') ppf =
  match lst with
  | [] -> Format.fprintf ppf "%t" (print_computation ~pure st c')
  | (p, c) :: lst ->
    if pure then
      Format.fprintf ppf "let %t = %t in %t"
        (print_pattern p) (print_computation ~pure st c) (print_multiple_bind ~pure st (lst, c'))
    else
      Format.fprintf ppf "%t >> fun %t -> %t"
        (print_computation ~pure st c) (print_pattern p) (print_multiple_bind ~pure st (lst, c'))

(* and print_let_abstraction st (p, c) ppf =
   Format.fprintf ppf "%t = %t" (print_pattern p) (print_computation st c) *)

and print_top_let_abstraction st (p, c) ppf =
  match c.Typed.term with
  | Typed.Value e -> 
    Format.fprintf ppf "%t = %t" (print_pattern p) (print_expression ~max_level:0 st e)
  | _ -> 
    Format.fprintf ppf "%t = run %t" (print_pattern p) (print_computation ~max_level:0 ~pure:false st c)

and print_let_rec_abstraction st (x, a) ppf =
  let pure = is_pure_abstraction st a in
  Format.fprintf ppf "%t = fun %t" (print_variable x) (print_abstraction ~pure st a)


(** COMMANDS *)

let compiled_filename fn = fn ^ ".ml"

let print_tydefs tydefs ppf =
  Format.fprintf ppf "type %t" (Print.sequence "\nand\n" print_tydef tydefs)

let print_computation_effects ?max_level c ppf =
  let print ?at_level = Print.print ?max_level ?at_level ppf in
  let get_dirt (_,(_,dirt),_) = dirt in
  let get_type (_,(ty,dirt),_) = ty in
  let rest = (get_dirt(c.Typed.scheme)).Type.rest in
  (* Here we have access to the effects *)
  (
    Format.fprintf ppf "Effects of a computation: \n";
    let f elem =
      Format.fprintf ppf "\t%t\n" (print_effect_region elem) in
    List.iter f (get_dirt(c.Typed.scheme)).Type.ops;
    Format.fprintf ppf "\nRest: %t\n" (Params.print_dirt_param rest);
    Format.fprintf ppf "Type: %t\n" (print_type (get_type(c.Typed.scheme)));
  )

let print_command st (cmd, _) ppf =
  match cmd with
  | Typed.DefEffect (eff, (ty1, ty2)) ->
    Print.print ppf "type (_, _) effect += %t : (%t, %t) effect" (print_effect eff) (print_type ty1) (print_type ty2)
  | Typed.Computation c ->
    print_computation ~pure:false st c ppf
  | Typed.TopLet (defs, _) ->
    Print.print ppf "let %t" (Print.sequence "\nand\n" (print_top_let_abstraction st) defs)
  | Typed.TopLetRec (defs, _) ->
    let st = determine_pure_recursive_functions st defs in
    Print.print ppf "let rec %t" (Print.sequence "\nand\n" (print_let_rec_abstraction st) defs)
  | Typed.Use fn ->
    Print.print ppf "#use %S" (compiled_filename fn)
  | Typed.External (x, ty, f) ->
    Print.print ppf "let %t = ( %s )" (print_variable x) f
  | Typed.Tydef tydefs ->
    print_tydefs tydefs ppf
  | Typed.Reset ->
    Print.print ppf "(* #reset directive not supported by OCaml *)"
  | Typed.Quit ->
    Print.print ppf "(* #quit directive not supported by OCaml *)"
  | Typed.TypeOf _ ->
    Print.print ppf "(* #type directive not supported by OCaml *)"
  | Typed.Help ->
    Print.print ppf "(* #help directive not supported by OCaml *)"

let print_commands cmds ppf =
  let st = initial in
  Print.sequence "\n\n;;\n\n" (print_command st) cmds ppf


(** THE REST *)

let print_computation_effects ?max_level c ppf =
  let print ?at_level = Print.print ?max_level ?at_level ppf in
  let get_dirt (_,(_,dirt),_) = dirt in
  (* Here we have access to the effects *)
  (Format.fprintf ppf "Effects of a computation: \n";
   let f elem =
     Format.fprintf ppf "\t%t" (print_effect elem) in
   List.iter f (get_dirt(c.Typed.scheme)).Type.ops;)