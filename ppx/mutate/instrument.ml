(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* A guard replaces its site in place and its disarmed arm is the original
   expression, so the rewriter is a map that threads one context: whether an
   expression must be a boolean, whether it is a condition, and whether its
   value is discarded. Every arm keeps the emission law of instrument.mli,
   because all the mutants share one binary and one ill-typed arm breaks the
   build of the whole project. *)

open Ppxlib
open Ast_builder.Default

(* Attributes *)

type directive = No_directive | Off of string | On | Exclude_file

(* The grammar is the [coverage] attribute's (ppx/coverage/instrument.ml). *)
let directive { attr_name; attr_payload; attr_loc } =
  let payload =
    match attr_payload with
    | PStr [ { pstr_desc = Pstr_eval (payload, _); _ } ] ->
        Some payload.pexp_desc
    | _ -> None
  in
  if not (String.equal attr_name.txt "mutate") then No_directive
  else
    match payload with
    | Some (Pexp_ident { txt = Lident "off"; _ }) -> Off ""
    | Some (Pexp_ident { txt = Lident "on"; _ }) -> On
    | Some (Pexp_ident { txt = Lident "exclude_file"; _ }) -> Exclude_file
    | Some
        (Pexp_apply
           ( { pexp_desc = Pexp_ident { txt = Lident "off"; _ }; _ },
             [
               ( Nolabel,
                 { pexp_desc = Pexp_constant (Pconst_string (reason, _, _)); _ }
               );
             ] )) ->
        Off reason
    | _ ->
        Location.raise_errorf ~loc:attr_loc "Bad payload in mutate attribute."

let err_misplaced attribute name =
  Location.raise_errorf ~loc:attribute.attr_loc "mutate %s is not allowed here."
    name

(* Every attribute is read, so a malformed one is an error beside an [off]
   too. *)
let off_reason attributes =
  List.fold_left
    (fun found attribute ->
      match directive attribute with
      | No_directive -> found
      | Off reason -> Some reason
      | On -> err_misplaced attribute "on"
      | Exclude_file -> err_misplaced attribute "exclude_file")
    None attributes

let is_off attributes = Option.is_some (off_reason attributes)

(* ppxlib encodes a construct that its syntax tree does not have, as a
   labeled tuple of OCaml 5.4 or an effect case of OCaml 5.3, as an
   extension node with one of these names. *)
let is_encoding name = String.starts_with ~prefix:"ppxlib.migration." name

(* The parser puts a postfix attribute on the last alternative of an
   or-pattern and on the last component of a tuple, so in [| A | B [@mutate
   off]] the attribute is not on the pattern of the case. A [mutate]
   attribute inside the pattern of a case is thus an error, and not a
   dismissal that has no effect. *)
let reject_inner_attributes p =
  let check =
    object
      inherit Ast_traverse.iter as super

      method! pattern p =
        List.iter
          (fun attribute ->
            match directive attribute with
            | No_directive -> ()
            | Off _ ->
                Location.raise_errorf ~loc:attribute.attr_loc
                  "mutate off is not allowed inside a pattern. Put it on the \
                   whole pattern of the case."
            | On -> err_misplaced attribute "on"
            | Exclude_file -> err_misplaced attribute "exclude_file")
          p.ppat_attributes;
        super#pattern p

      (* An encoding holds the sub-patterns of the source in its payload. *)
      method! extension ((name, _) as extension) =
        if is_encoding name.txt then super#extension extension

      method! attribute _ = ()
    end
  in
  check#pattern_desc p.ppat_desc

let excludes_file structure =
  List.exists
    (function
      | { pstr_desc = Pstr_attribute attribute; _ } -> (
          match directive attribute with
          | Exclude_file -> true
          | No_directive | Off _ | On -> false)
      | _ -> false)
    structure

(* Inline tests *)

(* ppx_windtrap marks each item it generates for a test with
   [[@@windtrap.test]]. Without ppx_windtrap a test stays an extension node,
   which is never traversed. *)
let is_test_item si =
  let marked =
    List.exists (fun a -> String.equal a.attr_name.txt "windtrap.test")
  in
  match si.pstr_desc with
  | Pstr_value (_, bindings) ->
      List.exists (fun b -> marked b.pvb_attributes) bindings
  | Pstr_module mb -> marked mb.pmb_attributes
  | _ -> false

(* Operators *)

(* [Flip] is the part of [lit] that names [true] and [false], which a file
   loses without the rest of [lit]. *)
type family = Ari | Cmp | Con | Arm | Call | Lit | Flip | Ret

(* Each rewritten operator with its family, the name of its rewrite and the
   operator that replaces it. *)
let operators =
  [
    ("+", (Ari, "sub", "-"));
    ("-", (Ari, "add", "+"));
    ("+.", (Ari, "fsub", "-."));
    ("-.", (Ari, "fadd", "+."));
    ("<", (Cmp, "le", "<="));
    ("<=", (Cmp, "lt", "<"));
    (">", (Cmp, "ge", ">="));
    (">=", (Cmp, "gt", ">"));
    ("=", (Cmp, "neq", "<>"));
    ("<>", (Cmp, "eq", "="));
    ("&&", (Con, "or", "||"));
    ("||", (Con, "and", "&&"));
  ]

(* A family keeps its sites only where its operators are Stdlib's: [ari]
   names its replacement, [con] turns [&&] into an [if], and [cmp] swaps
   operands of one type. A binding that this pass sees loses the family of
   its name; what an [open] brings in is not seen. A file that declares a
   constructor of a guard, in a type or as an extension constructor, loses
   the family of the guard: [()] that of [call], whose [let () = e] then
   names it, [true] or [false] that of [arm], whose constructors warning 42
   then reports, and the [flip] rewrite of [lit]. A constructor [Some],
   [None] or [(::)] of the file can be the one that a [ret] site applies,
   and the guard then gives the wrong type, so the file loses [ret]. *)
let kept_families structure =
  let lose name lost =
    match List.assoc_opt name operators with
    | Some (family, _, _) -> family :: lost
    | None -> lost
  in
  let lose_constructor name lost =
    match name with
    | "()" -> Call :: lost
    | "true" | "false" -> Arm :: Flip :: lost
    | "Some" | "None" | "::" -> Ret :: lost
    | _ -> lost
  in
  let scan =
    object
      inherit [family list] Ast_traverse.fold as super

      method! pattern p lost =
        let lost =
          match p.ppat_desc with
          | Ppat_var { txt; _ } -> lose txt lost
          | _ -> lost
        in
        super#pattern p lost

      method! value_description vd lost =
        super#value_description vd (lose vd.pval_name.txt lost)

      method! constructor_declaration cd lost =
        super#constructor_declaration cd (lose_constructor cd.pcd_name.txt lost)

      method! extension_constructor ec lost =
        super#extension_constructor ec (lose_constructor ec.pext_name.txt lost)
    end
  in
  let lost = scan#structure structure [] in
  fun family -> not (List.mem family lost)

(* Mutants *)

(* [Condition] is an [if] or [while] condition or the guard of a case, and
   [Boolean] a direct operand of [&&] or [||]. [cmp] fires in these two
   alone, where the expression must be a boolean, so that a user's comparison
   cannot give its two arms two types. [Statement] is the left operand of a
   sequence and [Unit_binding] the expression of [let () = e in body]: the
   code discards their value, and [call] fires in these two alone. *)
type context = Condition | Boolean | Statement | Unit_binding | Ordinary

(* A bare operator applied to two unlabelled arguments. A qualified operator
   may be anything, and is no site. *)
type application = {
  name : string;
  operator : expression;
  left : expression;
  right : expression;
}

let application e =
  match e.pexp_desc with
  | Pexp_apply
      ( ({ pexp_desc = Pexp_ident { txt = Lident name; _ }; _ } as operator),
        [ (Nolabel, left); (Nolabel, right) ] ) ->
      Some { name; operator; left; right }
  | _ -> None

let applies name e =
  match application e with
  | Some app -> String.equal app.name name
  | None -> false

let is_connective ~keeps e = keeps Con && (applies "&&" e || applies "||" e)

(* [apply ~loc name args] applies the bare operator [name] to [args]. *)
let apply ~loc name args =
  pexp_apply ~loc
    (pexp_ident ~loc { txt = Lident name; loc })
    (List.map (fun arg -> (Nolabel, arg)) args)

(* The printer of ppxlib prints an encoding as it is. A node that holds one
   is thus converted to the parsetree of the compiler, which decodes it, and
   the printer of the compiler prints it. *)
let holds_encoding =
  object
    inherit [bool] Ast_traverse.fold as super

    method! extension ((name, _) as extension) found =
      found || is_encoding name.txt || super#extension extension found
  end

let print_expression e =
  if holds_encoding#expression e false then
    Astlib.Compiler_pprintast.string_of_expression
      (Selected_ast.To_ocaml.copy_expression e)
  else Pprintast.string_of_expression e

let print_pattern p =
  if holds_encoding#pattern p false then
    Format.asprintf "%a" Astlib.Compiler_pprintast.pattern
      (Selected_ast.To_ocaml.copy_pattern p)
  else Format.asprintf "%a" Pprintast.pattern p

(* A text is printed from the parsetree, since a preprocessor cannot rely on
   the path of its source, and each run of blanks becomes one space. *)
let one_line text =
  String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c) text
  |> String.split_on_char ' '
  |> List.filter (fun word -> word <> "")
  |> String.concat " "

(* When the coverage rewriter ran first, its wrapper
   [___windtrap_post_visit___ n call] stands in place of [call]. *)
let post_visit e =
  match e.pexp_desc with
  | Pexp_apply
      ( ({
           pexp_desc = Pexp_ident { txt = Lident "___windtrap_post_visit___"; _ };
           _;
         } as visit),
        [ (Nolabel, n); (Nolabel, call) ] ) ->
      Some (visit, n, call)
  | _ -> None

(* A text has no attribute of the expression, nor of the call in its
   wrapper. *)
let rec bare e =
  match post_visit e with
  | Some (visit, n, call) ->
      {
        e with
        pexp_desc = Pexp_apply (visit, [ (Nolabel, n); (Nolabel, bare call) ]);
        pexp_attributes = [];
      }
  | None -> { e with pexp_attributes = [] }

let render e = one_line (print_expression (bare e))

(* The texts of an [arm] site are the pattern and the guard of its case,
   and [...] stands for its body, which the source line of the report
   shows. *)
let render_arm c ~guard =
  let pattern = print_pattern { c.pc_lhs with ppat_attributes = [] } in
  one_line
    (Printf.sprintf "| %s%s -> ..." pattern
       (match guard with None -> "" | Some g -> " when " ^ g))

(* How a guard arms its site. The emission law forbids naming a comparison's
   partner, so [cmp] negates the operator the source wrote: on a total order
   [a <= b] is [not (b < a)], so an ordering swaps its operands, and [a <> b]
   is [not (a = b)], so an equality does not. *)
type guard =
  | Neg
  | Skip (* [call] *)
  | Constant of expression (* [lit], by this constant *)
  | Nothing (* [ret] on [Some e] *)
  | Tail of expression (* [ret] on [h :: t], with [t] *)
  | Operator of application * operator_guard

and operator_guard =
  | Negate (* [cmp] on an equality *)
  | Swap (* [cmp] on an ordering *)
  | Branch (* [con] *)
  | Replace of string (* [ari], by this operator *)

type mutant = { guard : guard; rewrite : string; after : string }

(* [called e] is the application of the user that [e] is. When the coverage
   rewriter ran first, its visit [___windtrap_visit___ n] stands in a
   statement, and to skip it changes nothing. To skip the wrapper of a call
   skips the call. *)
let rec called e =
  match (post_visit e, e.pexp_desc) with
  | Some (_, _, call), _ -> called call
  | None, Pexp_apply ({ pexp_desc = Pexp_ident { txt = Lident name; _ }; _ }, _)
    when String.starts_with ~prefix:"___windtrap_" name ->
      None
  | None, Pexp_apply _ -> Some e
  | None, _ -> None

(* The attributes of [e] and of the call that it wraps, so that a dismissal
   of a call holds in the two orders of the rewriters. *)
let attributes e =
  match called e with
  | Some call when call != e -> e.pexp_attributes @ call.pexp_attributes
  | Some _ | None -> e.pexp_attributes

(* [successor s suffix] is [Some (zero, next)] when [s] with [suffix] is an
   integer literal of the compiler: [zero] tells if its value is 0, and
   [next] is its value plus one, in decimal. The compiler reads a literal
   without a sign as the negation of the negative one, so that the least
   integer has a literal, and so does this. The sum wraps as the addition
   of the type does. The compiler does a check of the range of a literal
   with the [int] and the [nativeint] of its process, as this does, and the
   word size of that process is the word size of the rewriter. Another
   suffix is the code of another rewriter. *)
let successor s suffix =
  let next of_string to_string succ neg zero =
    let n =
      if String.starts_with ~prefix:"-" s then of_string s
      else neg (of_string ("-" ^ s))
    in
    (n = zero, to_string (succ n))
  in
  match suffix with
  | None -> Some (next int_of_string Int.to_string Int.succ Int.neg 0)
  | Some 'l' ->
      Some (next Int32.of_string Int32.to_string Int32.succ Int32.neg 0l)
  | Some 'L' ->
      Some (next Int64.of_string Int64.to_string Int64.succ Int64.neg 0L)
  | Some 'n' ->
      Some
        (next Nativeint.of_string Nativeint.to_string Nativeint.succ
           Nativeint.neg 0n)
  | Some _ -> None

(* [literal ~keeps context e] is the [lit] mutant of [e], when [e] is a
   literal. An integer becomes its successor, under [one] for [0] and [inc]
   for the others. A float other than zero becomes [0.] under [zero], and a
   zero becomes [1.] under [one]. [true] and [false] swap under [flip],
   except in a condition, where [neg] gives the same mutant. A string and a
   character are no sites. An integer literal that its type cannot hold is no
   site, so that the compiler reports the error. Every float literal of the
   lexer is read, so a float that is not read comes from another rewriter. *)
let literal ~keeps context e =
  let loc = { e.pexp_loc with loc_ghost = true } in
  let mutant rewrite armed =
    Some { guard = Constant armed; rewrite; after = render armed }
  in
  let constant rewrite c = mutant rewrite (pexp_constant ~loc c) in
  match e.pexp_desc with
  | Pexp_constant (Pconst_integer (s, suffix)) when keeps Lit -> (
      match successor s suffix with
      | Some (zero, next) ->
          constant
            (if zero then "one" else "inc")
            (Pconst_integer (next, suffix))
      | None | (exception Failure _) -> None)
  | Pexp_constant (Pconst_float (s, None)) when keeps Lit -> (
      match Float.equal (float_of_string s) 0. with
      | true -> constant "one" (Pconst_float ("1.", None))
      | false -> constant "zero" (Pconst_float ("0.", None))
      | exception Failure _ -> None)
  | Pexp_construct ({ txt = Lident (("true" | "false") as name); _ }, None)
    when keeps Flip && context <> Condition ->
      let other = if String.equal name "true" then "false" else "true" in
      mutant "flip" (pexp_construct ~loc { txt = Lident other; loc } None)
  | _ -> None

(* [cons e] is [Some (h, t)] when [e] is [h :: t]. *)
let cons e =
  match e.pexp_desc with
  | Pexp_construct
      ({ txt = Lident "::"; _ }, Some { pexp_desc = Pexp_tuple [ h; t ]; _ }) ->
      Some (h, t)
  | _ -> None

(* [returned ~keeps e] is the [ret] mutant of [e], when [e] applies [Some]
   or [(::)]. [Some e] becomes [None] under [none], and [h :: t] becomes [t]
   under [tail]. *)
let returned ~keeps e =
  if not (keeps Ret) then None
  else
    match (e.pexp_desc, cons e) with
    | Pexp_construct ({ txt = Lident "Some"; _ }, Some _), _ ->
        Some { guard = Nothing; rewrite = "none"; after = "None" }
    | _, Some (_, tail) ->
        Some { guard = Tail tail; rewrite = "tail"; after = render tail }
    | _, None -> None

(* A connective with a connective operand carries no mutant, since its guard
   would hold another site. [neg] and [call] come last, each in its own
   contexts. No other mutant shares an expression with [lit] or [ret]. *)
let mutant ~keeps context e =
  let loc = e.pexp_loc in
  let last () =
    match context with
    | Condition ->
        let negated = apply ~loc "not" [ bare e ] in
        Some { guard = Neg; rewrite = "not"; after = render negated }
    | (Statement | Unit_binding) when keeps Call && Option.is_some (called e) ->
        Some { guard = Skip; rewrite = "skip"; after = "()" }
    | Statement | Unit_binding | Boolean | Ordinary -> None
  in
  match application e with
  | None -> (
      match literal ~keeps context e with
      | Some _ as mutant -> mutant
      | None -> (
          match returned ~keeps e with
          | Some _ as mutant -> mutant
          | None -> last ()))
  | Some app -> (
      match List.assoc_opt app.name operators with
      | Some (family, rewrite, replacement) when keeps family -> (
          let after = render (apply ~loc replacement [ app.left; app.right ]) in
          let mutant guard =
            Some { guard = Operator (app, guard); rewrite; after }
          in
          match family with
          | Con ->
              if is_connective ~keeps app.left || is_connective ~keeps app.right
              then None
              else mutant Branch
          | Cmp when context <> Condition && context <> Boolean -> last ()
          | Cmp ->
              mutant
                (if app.name = "=" || app.name = "<>" then Negate else Swap)
          | Ari -> mutant (Replace replacement)
          | Arm | Call | Lit | Flip | Ret (* no operator *) -> last ())
      | Some _ | None -> last ())

(* Guards *)

(* A binder is site-indexed in a reserved namespace, so that a guard shadows
   neither a user's binding nor another guard's. *)
let binder index role = Printf.sprintf "__windtrap_mut_%d_%s" index role

(* The module is named after the file, so that each compilation unit calls its
   own. The coverage rewriter mangles its module in the same way. *)
let generated_module_name file =
  let buffer = Buffer.create (String.length file + 16) in
  Buffer.add_string buffer "Windtrap_mut___";
  String.iter
    (function
      | ('A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_') as c ->
          Buffer.add_char buffer c
      | _ -> Buffer.add_string buffer "___")
    file;
  Buffer.contents buffer

let armed ~loc ~module_name index =
  pexp_apply ~loc
    (pexp_ident ~loc
       { txt = Ldot (Lident module_name, "___windtrap_armed___"); loc })
    [ (Nolabel, eint ~loc index) ]

(* [neg], and [cmp] on an equality. The value is bound once, so it is
   evaluated as often as before, and binding the whole comparison leaves its
   operands the order the compiler gives them. *)
let negation ~loc ~module_name ~index value =
  let p = binder index "p" in
  [%expr
    let [%p pvar ~loc p] = [%e value] in
    if [%e armed ~loc ~module_name index] then Stdlib.not [%e evar ~loc p]
    else [%e evar ~loc p]]

(* [cmp] on an ordering, and [ari]: [let l, r = left, right in if armed then
   ... else l op r], where the disarmed arm is the application of [e] rebuilt
   over the binders, with its location and its attributes.

   The type-checker reads the tuple left to right, as it reads the arguments
   of an application, so a qualified field of the left operand still resolves
   an unqualified field of the right one. The match compiler destructures the
   literal tuple without building it, into the [let] chain the application
   compiles to, right operand first: each operand is evaluated once, in the
   original order, with no allocation. A [let] chain written here would impose
   one order on both, and a right-to-left check breaks that disambiguation.

   An application also checks its right argument against the type of the left
   one, which resolves a constructor or a record literal whose name a later
   type declaration reuses. [~pin] restores that for an ordering by the
   annotation [_ operands], with [type 'a operands = 'a * 'a]. The swapped arm
   already needs one type for both operands, so the pin rejects nothing. A
   variable [: 'a] cannot say it: it is scoped to the whole toplevel phrase,
   so it would tie the phrase's sites together and keep a local
   [let lt x y = x < y] from generalizing. [ari] does not pin, since an
   [open]-provided [+] may take two types, and number types disambiguate
   nothing.

   An applied [(fun l r -> ...) left right] would keep its call and its
   closure in bytecode under [-g]. Binding the operator, as in [let op = if
   armed then ( <= ) else ( < )], names a second operator, and reaches the
   polymorphic comparison even when nothing is armed. *)
let binary ~loc ~module_name ~index ~pin e app ~armed_arm left right =
  let l = binder index "l" and r = binder index "r" in
  let operands =
    let tuple = pexp_tuple ~loc [ left; right ] in
    if not pin then tuple
    else
      pexp_constraint ~loc tuple
        (ptyp_constr ~loc
           { txt = Ldot (Lident module_name, "operands"); loc }
           [ ptyp_any ~loc ])
  in
  let disarmed =
    {
      (pexp_apply ~loc:e.pexp_loc app.operator
         [ (Nolabel, evar ~loc l); (Nolabel, evar ~loc r) ])
      with
      pexp_attributes = e.pexp_attributes;
    }
  in
  [%expr
    let [%p pvar ~loc l], [%p pvar ~loc r] = [%e operands] in
    if [%e armed ~loc ~module_name index] then
      [%e armed_arm (evar ~loc l) (evar ~loc r)]
    else [%e disarmed]]

(* [con] branches once on the armed flag, which keeps the short circuit, the
   tail position of [b] and one copy of each operand:

     a && b  ->  let p = a in
                 if Stdlib.( <> ) (p : Stdlib.Bool.t) (armed i) then b else p
     a || b  ->  let p = a in
                 if Stdlib.( = ) (p : Stdlib.Bool.t) (armed i) then b else p

   Armed, the first reads [if not p then b else p], which is [a || b]. The
   constraint makes the comparison an integer one, and it names
   [Stdlib.Bool.t] because a file may declare its own [bool]. No node of the
   guard is the original expression, so the whole guard takes its
   attributes. *)
let branch ~loc ~module_name ~index e app left right =
  let p = binder index "p" in
  let value = [%expr ([%e evar ~loc p] : Stdlib.Bool.t)] in
  let armed = armed ~loc ~module_name index in
  let test =
    if String.equal app.name "&&" then
      [%expr Stdlib.( <> ) [%e value] [%e armed]]
    else [%expr Stdlib.( = ) [%e value] [%e armed]]
  in
  {
    ([%expr
       let [%p pvar ~loc p] = [%e left] in
       if [%e test] then [%e right] else [%e evar ~loc p]])
    with
    pexp_attributes = e.pexp_attributes;
  }

(* [call] skips its application when armed. In a sequence the application
   stays the left operand of one, so it types as before, with or without
   [-strict-sequence]. In [let () = e] the expected type [unit] reaches [e]
   through the [if]. The one [()] of the guard stands where [unit] is
   expected, so a file's own constructor [()] cannot capture it. *)
let skip ~loc ~module_name ~index context value =
  let live = [%expr Stdlib.not [%e armed ~loc ~module_name index]] in
  match context with
  | Unit_binding -> [%expr if [%e live] then [%e value]]
  | Statement | Condition | Boolean | Ordinary ->
      [%expr
        if [%e live] then (
          [%e value];
          ())]

(* [lit] replaces its literal when armed, and [ret] gives [None] in place
   of [Some e], whose [e] is then not evaluated. The constructors stand where
   the type of the literal and the type of [Some e] are expected. *)
let constant ~loc ~module_name ~index ~armed:armed_arm value =
  [%expr
    if [%e armed ~loc ~module_name index] then [%e armed_arm] else [%e value]]

let nothing ~loc ~module_name ~index value =
  [%expr if [%e armed ~loc ~module_name index] then None else [%e value]]

(* [ret] on [h :: t] gives [t] alone when armed, without [h]. The armed arm
   is a copy of [t] as the source wrote it, so the one [t] of the original
   is evaluated in its place, and no binding changes when the type-checker
   reads [t]. The original comes first: the type-checker reads the branches
   of an [if] in order, so [h] still gives its type to [t] as in the
   original, and the copy gets the type of the original. The sites inside
   the copy are not guarded, because when the copy runs, its own site is
   the armed one. The copy has ghost locations, as generated code has, so
   that the coverage rewriter gives it no point when it runs next, and two
   nodes never share one location. *)
let ghost =
  object
    inherit Ast_traverse.map
    method! location loc = { loc with loc_ghost = true }
  end

let tail ~loc ~module_name ~index value original_tail =
  [%expr
    if Stdlib.not [%e armed ~loc ~module_name index] then [%e value]
    else [%e ghost#expression original_tail]]

(* [arm] gives a case a guard that is [false] when armed, so that the value
   goes to the next case that matches it. A guard that the case has runs
   after the armed flag, as before. The guard is an [if] and not an
   application, because the type-checker reads the branches of an [if] and
   not its condition: a match whose cases are syntactic values stays one, and
   its binding still generalizes. The constructors stand where [bool] is
   expected. *)
let arm_guard ~loc ~module_name ~index guard =
  let otherwise = Option.value guard ~default:[%expr true] in
  [%expr if [%e armed ~loc ~module_name index] then false else [%e otherwise]]

(* [silence ~loc warnings e] is [e] with [[@ocaml.warning warnings]], the
   [warning_attribute], before its attributes. A guarded case does not
   count for exhaustiveness, so a match whose every case is guarded is
   partial for the compiler (8). A dropped case then raises [Match_failure],
   which is the mutant. Warning 57 examines a guard against the earlier
   cases without a guard alone, so an [arm] guard on an earlier case can
   make an or-pattern variable ambiguous in a later guarded case. The
   compiler applies the attributes of a node from the last to the first.
   The generated attribute thus applies last, and a warning attribute of the
   user cannot turn these warnings on again. *)
let warning_attribute ~loc warnings =
  attribute ~loc
    ~name:{ txt = "ocaml.warning"; loc }
    ~payload:(PStr [ pstr_eval ~loc (estring ~loc warnings) [] ])

let silence ~loc warnings e =
  {
    e with
    pexp_attributes = warning_attribute ~loc warnings :: e.pexp_attributes;
  }

let is_refutation c =
  match c.pc_rhs.pexp_desc with Pexp_unreachable -> true | _ -> false

(* ppxlib encodes the effect pattern [effect e, k] of OCaml 5.3 as an
   extension with this prefix. The name is [ppat_effect] in ppxlib 0.37 and
   [ppat_effect_503] from ppxlib 0.38. *)
let is_effect p =
  match p.ppat_desc with
  | Ppat_extension ({ txt; _ }, _) ->
      String.starts_with ~prefix:"ppxlib.migration.ppat_effect" txt
  | _ -> false

(* [matches p] is whether [p] matches values and whether it matches
   exceptions. The compiler refuses a guard on a case that does both. An
   effect case matches neither. The compiler accepts an exception pattern
   under a local open and under a type constraint, as [M.(exception E)]. *)
let rec matches p =
  match p.ppat_desc with
  | _ when is_effect p -> (false, false)
  | Ppat_exception _ -> (false, true)
  | Ppat_open (_, inner) | Ppat_constraint (inner, _) -> matches inner
  | Ppat_or (a, b) ->
      let values_a, exceptions_a = matches a
      and values_b, exceptions_b = matches b in
      (values_a || values_b, exceptions_a || exceptions_b)
  | _ -> (true, false)

let matches_values p = fst (matches p)
let is_mixed p = matches p = (true, true)

let is_unit_binding vb =
  match vb.pvb_pat.ppat_desc with
  | Ppat_construct ({ txt = Lident "()"; _ }, None) -> true
  | _ -> false

(* Traversal *)

(* [lazy] of a trivial syntactic value compiles as already forced, and a
   guard under it would change that. Coverage's predicate, verbatim. No guard
   weakens the generalization of a binding. The site of an operator or of
   [call] is an application or a condition, which is never a syntactic
   value. An [arm] site is a case, and its guard is an [if], whose
   condition the type-checker does not read when it decides if a match is a
   syntactic value. *)
let rec is_trivial_syntactic_value e =
  match e.pexp_desc with
  | Pexp_function _ | Pexp_poly _ | Pexp_ident _ | Pexp_constant _
  | Pexp_construct (_, None) ->
      true
  | Pexp_constraint (inner, _) | Pexp_coerce (inner, _, _) ->
      is_trivial_syntactic_value inner
  | _ -> false

(* Nothing under an opaque expression is rewritten. The type-checker gives
   [assert false] every type only as written. *)
let is_opaque e =
  match e.pexp_desc with
  | Pexp_assert _ -> true
  | Pexp_lazy body -> is_trivial_syntactic_value body
  | _ -> false

type site = {
  line : int;
  col : int;
  rewrite : string;
  before : string;
  after : string;
  dismissed : string option;
}

class instrumenter ~keeps ~module_name =
  object (self)
    inherit Ast_traverse.map as super

    (* The identifier of every recorded site, so its length is the next
       index. *)
    val seen = Hashtbl.create 64
    val mutable sites = [] (* newest first *)
    val mutable pins = false (* a guard names [operands] *)
    val mutable suppressed = false (* inside a [[@@@mutate off]] region *)

    (* The right-hand side of a [let rec] cannot be an [if] that reads a
       variable that the [let rec] binds, so a [ret] guard has no place
       there. [recursive] tells that the expression is in such a right-hand
       side, outside the functions and the [lazy] bodies in it, whose
       evaluation comes later. *)
    val mutable recursive = false
    method sites = List.rev sites
    method pins = pins

    method private within_recursive : 'a. bool -> (unit -> 'a) -> 'a =
      fun flag f ->
        let outer = recursive in
        recursive <- flag;
        let result = f () in
        recursive <- outer;
        result

    method private keeps family = keeps family && not (recursive && family = Ret)

    (* [record loc ...] records a site at [loc] and is its index. It is
       [None], with nothing recorded, for generated code and for a site whose
       identifier another one has, as a deriver's copy does. *)
    method private record (loc : location) ~rewrite ~before ~after ~dismissed =
      let start = loc.loc_start in
      let line = start.pos_lnum and col = start.pos_cnum - start.pos_bol in
      let key = (line, col, rewrite) in
      if loc.loc_ghost || Hashtbl.mem seen key then None
      else begin
        let index = Hashtbl.length seen in
        Hashtbl.add seen key ();
        sites <- { line; col; rewrite; before; after; dismissed } :: sites;
        Some index
      end

    method private site e (mutant : mutant) ~dismissed =
      self#record e.pexp_loc ~rewrite:mutant.rewrite ~before:(render e)
        ~after:mutant.after ~dismissed

    (* [chained] marks the left operand of a site that applies the same
       operator: a chain of one operator carries one mutant, and reading it
       from the tree keeps a bracket from changing the count. A dismissal
       leaves [e] as written. *)
    method private mutate ?(chained = false) context e =
      let off = off_reason (attributes e) in
      if is_opaque e then e
      else
        match (e.pexp_desc, off, mutant ~keeps:self#keeps context e) with
        | (Pexp_function _ | Pexp_lazy _), _, _ when recursive ->
            self#within_recursive false (fun () ->
                self#mutate ~chained context e)
        | _, Some _, None -> e
        | _, Some reason, Some mutant ->
            if not chained then
              ignore (self#site e mutant ~dismissed:(Some reason));
            e
        | _, None, None -> self#descend e
        | _, None, Some mutant ->
            let index =
              if chained then None else self#site e mutant ~dismissed:None
            in
            self#guard context e mutant index

    method private guard context e mutant index =
      let loc = { e.pexp_loc with loc_ghost = true } in
      match mutant.guard with
      | Neg -> (
          let value = self#descend e in
          match index with
          | None -> value
          | Some index -> negation ~loc ~module_name ~index value)
      | Skip -> (
          let value = self#descend e in
          match index with
          | None -> value
          | Some index -> skip ~loc ~module_name ~index context value)
      | Constant armed -> (
          match index with
          | None -> e
          | Some index -> constant ~loc ~module_name ~index ~armed e)
      | Nothing -> (
          let value = self#descend e in
          match index with
          | None -> value
          | Some index -> nothing ~loc ~module_name ~index value)
      | Tail original_tail -> (
          let value = self#chain e in
          match index with
          | None -> value
          | Some index -> tail ~loc ~module_name ~index value original_tail)
      | Operator (app, guard) -> (
          let context =
            match guard with
            | Branch -> Boolean
            | Negate | Swap | Replace _ -> Ordinary
          in
          let chained = applies app.name app.left in
          let left = self#mutate ~chained context app.left in
          let right = self#mutate context app.right in
          let rebuilt =
            {
              e with
              pexp_desc =
                Pexp_apply (app.operator, [ (Nolabel, left); (Nolabel, right) ]);
            }
          in
          match index with
          | None -> rebuilt
          | Some index -> (
              match guard with
              | Negate -> negation ~loc ~module_name ~index rebuilt
              | Swap ->
                  pins <- true;
                  binary ~loc ~module_name ~index ~pin:true e app left right
                    ~armed_arm:(fun l r ->
                      let swapped =
                        pexp_apply ~loc app.operator
                          [ (Nolabel, r); (Nolabel, l) ]
                      in
                      [%expr Stdlib.not [%e swapped]])
              | Branch -> branch ~loc ~module_name ~index e app left right
              | Replace replacement ->
                  binary ~loc ~module_name ~index ~pin:false e app left right
                    ~armed_arm:(fun l r -> apply ~loc replacement [ l; r ])))

    (* [chain e] rewrites the head and the tail of [h :: t]. A tail that
       applies [(::)] too, as in [a :: b :: t], continues the chain of [e] and
       carries no [tail] site, as the [(::)] of a list literal carry none.
       Each [tail] guard holds a copy of its tail, and its text holds the
       text of its tail. A site at each [(::)] of a chain would thus make the
       code and the time of the rewriter grow as the square of the length of
       the chain. A dismissal of a tail leaves it as written. *)
    method private chain e =
      match e.pexp_desc with
      | Pexp_construct
          (constructor, Some ({ pexp_desc = Pexp_tuple [ h; t ]; _ } as pair))
        ->
          let h = self#expression h in
          let t =
            match cons t with
            | None -> self#expression t
            | Some _ when is_off t.pexp_attributes -> t
            | Some _ -> self#chain t
          in
          let pair = { pair with pexp_desc = Pexp_tuple [ h; t ] } in
          { e with pexp_desc = Pexp_construct (constructor, Some pair) }
      | _ -> self#descend e

    (* [descend e] rewrites the children of [e], each in the context that [e]
       gives it. A connective that carries no mutant still has boolean
       operands. *)
    method private descend e =
      match e.pexp_desc with
      | Pexp_ifthenelse (condition, then_, else_) ->
          {
            e with
            pexp_desc =
              Pexp_ifthenelse
                ( self#mutate Condition condition,
                  self#expression then_,
                  Option.map self#expression else_ );
          }
      | Pexp_while (condition, body) ->
          {
            e with
            pexp_desc =
              Pexp_while (self#mutate Condition condition, self#expression body);
          }
      | Pexp_apply (operator, [ (Nolabel, left); (Nolabel, right) ])
        when is_connective ~keeps:self#keeps e ->
          {
            e with
            pexp_desc =
              Pexp_apply
                ( operator,
                  [
                    (Nolabel, self#mutate Boolean left);
                    (Nolabel, self#mutate Boolean right);
                  ] );
          }
      | Pexp_sequence (first, rest) ->
          let first = self#mutate Statement first in
          let rest = self#expression rest in
          { e with pexp_desc = Pexp_sequence (first, rest) }
      | Pexp_let (rec_flag, bindings, body) ->
          let binding vb =
            if is_unit_binding vb then
              { vb with pvb_expr = self#mutate Unit_binding vb.pvb_expr }
            else self#value_binding vb
          in
          let bindings =
            self#within_recursive
              (recursive || rec_flag = Recursive)
              (fun () -> List.map binding bindings)
          in
          let body = self#expression body in
          { e with pexp_desc = Pexp_let (rec_flag, bindings, body) }
      | Pexp_match (scrutinee, cases) ->
          let scrutinee = self#expression scrutinee in
          let cases, armed = self#arms ~handlers:false cases in
          let e = { e with pexp_desc = Pexp_match (scrutinee, cases) } in
          if armed then
            silence ~loc:{ e.pexp_loc with loc_ghost = true } "-8-57" e
          else e
      | Pexp_function (params, constraint_, Pfunction_cases (cases, loc, attrs))
        ->
          let params = List.map self#function_param params in
          let constraint_ = Option.map self#type_constraint constraint_ in
          (* After parameters, the parser puts the attributes of [function]
             on its cases. A dismissal there thus leaves the cases as
             written, and the parameters keep their sites. The compiler
             applies the attributes in an inner scope, so the generated
             attribute also comes before them. *)
          let cases, armed =
            if is_off attrs then (cases, false)
            else self#arms ~handlers:false cases
          in
          let attrs =
            if armed && attrs <> [] then
              warning_attribute ~loc:{ loc with loc_ghost = true } "-8-57"
              :: attrs
            else attrs
          in
          let body = Pfunction_cases (cases, loc, attrs) in
          let e =
            { e with pexp_desc = Pexp_function (params, constraint_, body) }
          in
          if armed then
            silence ~loc:{ e.pexp_loc with loc_ghost = true } "-8-57" e
          else e
      | Pexp_try (body, cases) ->
          let body = self#expression body in
          let cases, armed = self#arms ~handlers:true cases in
          let e = { e with pexp_desc = Pexp_try (body, cases) } in
          if armed then
            silence ~loc:{ e.pexp_loc with loc_ghost = true } "-57" e
          else e
      | _ -> super#expression e

    (* [arms ~handlers cases] rewrites [cases] and tells if a case got a
       guard. [handlers] tells that the cases are those of a [try]. A match
       with a refutation case has no [arm] site, since a guard on a case
       before it makes it fail to type. The one case of a match that a value
       can reach is no site, since without it every value raises. An effect
       case is no site, because the family drops the cases of values and of
       exceptions alone. *)
    method private arms ~handlers cases =
      let reachable = List.filter (fun c -> matches_values c.pc_lhs) cases in
      let is_site c =
        self#keeps Arm
        && (not (List.exists is_refutation cases))
        && (not (is_effect c.pc_lhs))
        && (not (is_mixed c.pc_lhs))
        && (handlers
           || (not (matches_values c.pc_lhs))
           || List.compare_length_with reachable 1 > 0)
      in
      let armed = ref false and armed_value = ref false in
      let arm c =
        if not (is_site c) then self#case c
        else
          let off =
            reject_inner_attributes c.pc_lhs;
            off_reason c.pc_lhs.ppat_attributes
          in
          let before = render_arm c ~guard:(Option.map render c.pc_guard) in
          let after = render_arm c ~guard:(Some "false") in
          let index =
            self#record c.pc_lhs.ppat_loc ~rewrite:"drop" ~before ~after
              ~dismissed:off
          in
          let c = self#case c in
          match (off, index) with
          | Some _, _ | None, None -> c
          | None, Some index ->
              armed := true;
              if (not handlers) && matches_values c.pc_lhs then
                armed_value := true;
              let loc = { c.pc_lhs.ppat_loc with loc_ghost = true } in
              {
                c with
                pc_guard = Some (arm_guard ~loc ~module_name ~index c.pc_guard);
              }
      in
      let cases = List.map arm cases in
      (* When the cases without a guard cover every value, the type-checker
         finds the match total. After an [arm] guard fails, the compiled
         match can read a mutable field again, and then finds the match
         partial (74). The compiler gives warning 74 after the type-checker,
         so no attribute disables it. Each other case of a value thus gets
         the guard [true], and the match is partial for the type-checker
         too. A case that also matches an exception cannot have a guard. *)
      let steady c =
        if
          Option.is_none c.pc_guard && matches_values c.pc_lhs
          && not (is_mixed c.pc_lhs)
        then
          let loc = { c.pc_lhs.ppat_loc with loc_ghost = true } in
          { c with pc_guard = Some [%expr true] }
        else c
      in
      let cases = if !armed_value then List.map steady cases else cases in
      (cases, !armed)

    (* Inside a region, every structure item but a value binding reaches its
       expressions through here. *)
    method! expression e = if suppressed then e else self#mutate Ordinary e

    method! case c =
      {
        pc_lhs = self#pattern c.pc_lhs;
        pc_guard = Option.map (self#mutate Condition) c.pc_guard;
        pc_rhs = self#expression c.pc_rhs;
      }

    method! module_binding mb =
      if is_off mb.pmb_attributes then mb else super#module_binding mb

    (* A [let rec] of a class has the same restriction as one of an
       expression. *)
    method! class_expr ce =
      match ce.pcl_desc with
      | Pcl_let (rec_flag, bindings, body) ->
          let bindings =
            self#within_recursive
              (recursive || rec_flag = Recursive)
              (fun () -> List.map self#value_binding bindings)
          in
          let body = self#class_expr body in
          { ce with pcl_desc = Pcl_let (rec_flag, bindings, body) }
      | _ -> super#class_expr ce

    method! structure_item si =
      match si.pstr_desc with
      | Pstr_attribute attribute ->
          (match directive attribute with
          | No_directive -> ()
          | Off _ ->
              if suppressed then
                Location.raise_errorf ~loc:attribute.attr_loc
                  "Mutation is already off.";
              suppressed <- true
          | On ->
              if not suppressed then
                Location.raise_errorf ~loc:attribute.attr_loc
                  "Mutation is already on.";
              suppressed <- false
          | Exclude_file -> err_misplaced attribute "exclude_file");
          si
      | Pstr_value (rec_flag, bindings) when not suppressed ->
          let binding b =
            if is_off b.pvb_attributes then b
            else { b with pvb_expr = self#expression b.pvb_expr }
          in
          let bindings =
            self#within_recursive
              (recursive || rec_flag = Recursive)
              (fun () -> List.map binding bindings)
          in
          { si with pstr_desc = Pstr_value (rec_flag, bindings) }
      | _ -> super#structure_item si

    method! structure items =
      let outer = suppressed in
      let items =
        List.map
          (fun si -> if is_test_item si then si else self#structure_item si)
          items
      in
      suppressed <- outer;
      items

    method! extension extension = extension
    method! attribute attribute = attribute
  end

(* The generated module *)

(* The module re-exports the runtime's [site] type, so that the table names
   its fields without type-directed disambiguation: the runtime declares these
   labels on three records, and warning 42 is fatal under [-w +a -warn-error
   +a]. The type equation turns a runtime record that drifted into a compile
   error. Because of its labels the module is never opened, and a file whose
   every site is dismissed has no unused [open].

   [register] allocates the arrays of the file, so indices are file-local, and
   the stop comments hide the module from odoc. The module stands above the
   user's code, so it names [int], [option] and [Some] unqualified, which a
   guard cannot. *)
let runtime_initialization ~file ~module_name ~sites ~pins =
  let loc = { (Location.in_file file) with loc_ghost = true } in
  let site { line; col; rewrite; before; after; dismissed } =
    let dismissed =
      match dismissed with
      | None -> [%expr None]
      | Some reason -> [%expr Some [%e estring ~loc reason]]
    in
    [%expr
      {
        line = [%e eint ~loc line];
        col = [%e eint ~loc col];
        rewrite = [%e estring ~loc rewrite];
        before = [%e estring ~loc before];
        after = [%e estring ~loc after];
        dismissed = [%e dismissed];
      }]
  in
  let site_type =
    [%stri
      type site = Windtrap_runtime.Mutate.site = {
        line : int;
        col : int;
        rewrite : string;
        before : string;
        after : string;
        dismissed : string option;
      }]
  in
  let operands = [%stri type 'a operands = 'a * 'a] in
  let armed =
    [%stri
      let ___windtrap_armed___ =
        Windtrap_runtime.Mutate.register ~file:[%e estring ~loc file]
          ~sites:[%e pexp_array ~loc (List.map site sites)]]
  in
  let items =
    if pins then [ site_type; operands; armed ] else [ site_type; armed ]
  in
  let generated =
    pstr_module ~loc
      (module_binding ~loc
         ~name:{ txt = Some module_name; loc }
         ~expr:(pmod_structure ~loc items))
  in
  let stop_comment = [%stri [@@@ocaml.text "/*"]] in
  [ stop_comment; generated; stop_comment ]

(* Rewriting *)

(* The ignore lists are the coverage rewriter's. *)
let always_ignore_paths = [ "//toplevel//"; "(stdin)" ]
let always_ignore_basenames = [ ".ocamlinit"; "topfind" ]

let transform_impl_file ?(arm = true) ?(call = true) ?(lit = false)
    ?(ret = true) ctxt ast =
  let file = Expansion_context.Base.input_name ctxt in
  if
    List.mem file always_ignore_paths
    || List.mem (Filename.basename file) always_ignore_basenames
    || excludes_file ast
  then ast
  else
    let module_name = generated_module_name file in
    let kept = kept_families ast in
    let keeps = function
      | Arm -> arm && kept Arm
      | Call -> call && kept Call
      | Lit -> lit
      | Flip -> lit && kept Flip
      | Ret -> ret && kept Ret
      | (Ari | Cmp | Con) as family -> kept family
    in
    let instrumenter = new instrumenter ~keeps ~module_name in
    let instrumented = instrumenter#structure ast in
    match instrumenter#sites with
    | [] -> ast
    | sites ->
        runtime_initialization ~file ~module_name ~sites ~pins:instrumenter#pins
        @ instrumented
