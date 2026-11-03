(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* A guard replaces its site in place and its disarmed arm is the original
   expression, so the rewriter is a map that threads one context: whether an
   expression must be a boolean, and whether it is a condition. Every arm
   keeps the emission law of
   instrument.mli, because all the mutants share one binary and one ill-typed
   arm breaks the build of the whole project. *)

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

(* [Message] is the rule of the failure message, which reads [failwith] and
   [invalid_arg]. *)
type family = Ari | Cmp | Con | Ret | Message

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
   its name; what an [open] brings in is not seen. The guards of [none] and
   [tail] name the predefined [None] and give [t] the type of [h :: t], so a
   file that declares a constructor [Some], [None] or [(::)], in a type or as
   an extension constructor, loses them. A file that binds [failwith] or
   [invalid_arg] loses [Message]. *)
let kept_families structure =
  let lose name lost =
    match (name, List.assoc_opt name operators) with
    | _, Some (family, _, _) -> family :: lost
    | ("failwith" | "invalid_arg"), None -> Message :: lost
    | _, None -> lost
  in
  let lose_constructor name lost =
    match name with "Some" | "None" | "::" -> Ret :: lost | _ -> lost
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

(* [Condition] is an [if] or [while] condition or an arm's guard, and
   [Boolean] a direct operand of [&&] or [||]. [cmp] fires in these two
   alone, where the expression must be a boolean, so that a user's comparison
   cannot give its two arms two types. *)
type context = Condition | Boolean | Ordinary

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

(* A text is printed from the parsetree, since a preprocessor cannot rely on
   the path of its source, and each run of blanks becomes one space. *)
let render e =
  Pprintast.string_of_expression { e with pexp_attributes = [] }
  |> String.map (function '\t' | '\n' | '\r' -> ' ' | c -> c)
  |> String.split_on_char ' '
  |> List.filter (fun word -> word <> "")
  |> String.concat " "

(* How a guard arms its site. The emission law forbids naming a comparison's
   partner, so [cmp] negates the operator the source wrote: on a total order
   [a <= b] is [not (b < a)], so an ordering swaps its operands, and [a <> b]
   is [not (a = b)], so an equality does not. *)
type guard =
  | Neg
  | Operator of application * operator_guard
  | Literal of expression (* [int] and [bool], by this constant *)
  | Nothing (* [none] on [Some e] *)
  | Tail of expression (* [tail] on [h :: t], with [t] *)
  | Delete (* [del], whose guard [descend] builds *)

and operator_guard =
  | Negate (* [cmp] on an equality *)
  | Swap (* [cmp] on an ordering *)
  | Branch (* [con] *)
  | Replace of string (* [ari], by this operator *)

type mutant = { guard : guard; rewrite : string; after : string }

(* A connective with a connective operand carries no mutant, since its guard
   would hold another site. *)
let mutant ~keeps context e =
  let loc = e.pexp_loc in
  let neg () =
    if context <> Condition then None
    else
      let negated = apply ~loc "not" [ { e with pexp_attributes = [] } ] in
      Some { guard = Neg; rewrite = "not"; after = render negated }
  in
  match application e with
  | None -> neg ()
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
          | Cmp when context = Ordinary -> None
          | Cmp ->
              mutant
                (if app.name = "=" || app.name = "<>" then Negate else Swap)
          | Ari -> mutant (Replace replacement)
          | Ret | Message (* no operator *) -> neg ())
      | Some _ | None -> neg ())

(* Literals *)

type direction = Up | Down

(* [int] moves a literal by one in the type of its suffix: 1 to 0, and any
   other [n] to [n + 1], unless that leaves the type. Each [of_string] reads
   the literal as the compiler does, so a hexadecimal one may wrap. *)
let nudge text suffix =
  let nudge of_string to_string ~zero ~one ~succ ~max =
    match of_string text with
    | None -> None
    | Some n when n = one -> Some (Down, to_string zero)
    | Some n when n = max -> None
    | Some n -> Some (Up, to_string (succ n))
  in
  match suffix with
  | None ->
      nudge int_of_string_opt string_of_int ~zero:0 ~one:1 ~succ ~max:max_int
  | Some 'l' ->
      nudge Int32.of_string_opt Int32.to_string ~zero:0l ~one:1l
        ~succ:Int32.succ ~max:Int32.max_int
  | Some 'L' ->
      nudge Int64.of_string_opt Int64.to_string ~zero:0L ~one:1L
        ~succ:Int64.succ ~max:Int64.max_int
  | Some 'n' ->
      nudge Nativeint.of_string_opt Nativeint.to_string ~zero:0n ~one:1n
        ~succ:Nativeint.succ ~max:Nativeint.max_int
  | Some _ -> None

(* ROR's move on a comparison's constant, which [int] would repeat: [x < c]
   armed is [x <= c], which is [x < c + 1]. A constant on the left mirrors the
   operator. *)
let boundary_move ~constant_right = function
  | "<" -> Some (if constant_right then Up else Down)
  | "<=" -> Some (if constant_right then Down else Up)
  | ">" -> Some (if constant_right then Down else Up)
  | ">=" -> Some (if constant_right then Up else Down)
  | _ -> None

let last_name = function
  | { pexp_desc = Pexp_ident { txt = Lident name | Ldot (_, name); _ }; _ } ->
      Some name
  | _ -> None

(* An argument of [Hashtbl.create], [Buffer.create] and their kin is a
   capacity, which no test should pin. *)
let is_create fn =
  match last_name fn with
  | Some name -> String.ends_with ~suffix:"create" name
  | None -> false

(* The labels of an OS flag, which no test observes. *)
let os_flags = [ "cloexec" ]

(* A resource release: a call of a [close] function, also under [ignore] or a
   [try]. *)
let releases =
  [
    "close";
    "close_in";
    "close_out";
    "close_noerr";
    "close_in_noerr";
    "close_out_noerr";
    "closedir";
  ]

let rec is_release e =
  match e.pexp_desc with
  | Pexp_apply (fn, [ (Nolabel, arg) ])
    when Option.equal String.equal (last_name fn) (Some "ignore") ->
      is_release arg
  | Pexp_apply (fn, _) -> (
      match last_name fn with
      | Some name -> List.mem name releases
      | None -> false)
  | Pexp_try (body, _) -> is_release body
  | _ -> false

(* [cons e] is [Some (h, t)] when [e] is [h :: t]. *)
let cons e =
  match e.pexp_desc with
  | Pexp_construct
      ({ txt = Lident "::"; _ }, Some { pexp_desc = Pexp_tuple [ h; t ]; _ }) ->
      Some (h, t)
  | _ -> None

(* Equivalence *)

(* [x + 0] and [x - 0] are equal on every [int]. On floats [-0. +. 0.] is
   [0.] and [-0. -. 0.] is [-0.], so a float zero is no such operand. *)
let is_zero e =
  match e.pexp_desc with
  | Pexp_constant (Pconst_integer (s, None)) -> int_of_string_opt s = Some 0
  | _ -> false

(* An operand that gives one value each time and does nothing else, so that
   [a && a] and [a || a] are [a]. *)
let rec is_pure e =
  match e.pexp_desc with
  | Pexp_ident _ | Pexp_construct (_, None) -> true
  | Pexp_field (e, _) | Pexp_constraint (e, _) -> is_pure e
  | _ -> false

let rec is_irrefutable p =
  match p.ppat_desc with
  | Ppat_any | Ppat_var _ | Ppat_construct ({ txt = Lident "()"; _ }, None) ->
      true
  | Ppat_alias (p, _) | Ppat_constraint (p, _) -> is_irrefutable p
  | Ppat_tuple ps -> List.for_all is_irrefutable ps
  | _ -> false

let locations =
  [
    "__LOC__"; "__LINE__"; "__POS__"; "__LOC_OF__"; "__LINE_OF__"; "__POS_OF__";
  ]

(* What can give two copies of one text two values: what gives the location
   of the copy, as [assert], [__LOC__] and its kin, and [Match_failure] of a
   pattern that can fail or of a [match] or [function] whose guard can fail,
   and an extension node, which a later rewriter expands. *)
let locates =
  object
    inherit [bool] Ast_traverse.fold as super

    method! expression e found =
      found
      ||
      match e.pexp_desc with
      | Pexp_assert _ | Pexp_match _ | Pexp_function (_, _, Pfunction_cases _)
        ->
          true
      | Pexp_ident { txt = Lident name | Ldot (_, name); _ }
        when List.mem name locations ->
          true
      | _ -> super#expression e found

    method! pattern p found = found || not (is_irrefutable p)
    method! extension _ _ = true
  end

let erase_locations =
  object
    inherit Ast_traverse.map
    method! location _ = Location.none
  end

exception Larger

(* [size ~limit e] is the number of locations in [e], or [None] above
   [limit]. *)
let size ~limit e =
  let count = ref 0 in
  let counter =
    object
      inherit Ast_traverse.iter

      method! location _ =
        incr count;
        if !count > limit then raise_notrace Larger
    end
  in
  match counter#expression e with () -> Some !count | exception Larger -> None

(* The limit doubles, so that the check costs the size of the smaller tree.
   In an else-if chain the [else] branch holds the rest of the chain, and a
   full count at each [if] would take a time quadratic in its length. *)
let same_size a b =
  let rec within limit =
    match (size ~limit a, size ~limit b) with
    | Some m, Some n -> m = n
    | Some _, None | None, Some _ -> false
    | None, None -> within (2 * limit)
  in
  within 64

(* [same a b] tells that [a] and [b] are one expression at two places, with
   one value at each. The trees are compared, as texts lose the blanks of a
   string. *)
let same a b =
  same_size a b
  && erase_locations#expression a = erase_locations#expression b
  && not (locates#expression a false)

(* [calls p e] tells that [e] applies a function that [p] accepts, as
   [f x], [f @@ x] or [x |> f], or gives one to [Printf.ksprintf] or
   [Format.kasprintf]. *)
let calls p e =
  let is_operator name f =
    match f.pexp_desc with
    | Pexp_ident { txt = Lident op; _ } -> String.equal op name
    | _ -> false
  in
  let is_formatter f =
    match f.pexp_desc with
    | Pexp_ident
        {
          txt =
            ( Ldot (Lident "Printf", "ksprintf")
            | Ldot (Lident "Format", "kasprintf") );
          _;
        } ->
        true
    | _ -> false
  in
  match e.pexp_desc with
  | Pexp_apply (op, [ (Nolabel, f); _ ]) when is_operator "@@" op -> p f
  | Pexp_apply (op, [ _; (Nolabel, f) ]) when is_operator "|>" op -> p f
  | Pexp_apply (k, (Nolabel, f) :: _) when is_formatter k -> p f
  | Pexp_apply (f, _) -> p f
  | _ -> false

let names names f =
  match f.pexp_desc with
  | Pexp_ident { txt; _ } -> List.mem (Longident.name txt) names
  | _ -> false

let is_logger =
  names
    [
      "Logs.app"; "Logs.err"; "Logs.warn"; "Logs.info"; "Logs.debug"; "Logs.msg";
    ]

let is_failure =
  names [ "failwith"; "invalid_arg"; "Stdlib.failwith"; "Stdlib.invalid_arg" ]

let is_unit_binding vb =
  match vb.pvb_pat.ppat_desc with
  | Ppat_construct ({ txt = Lident "()"; _ }, None) -> true
  | _ -> false

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

(* [none] and [tail] keep the original first, so that the type-checker reads
   it as in the original: [None] then takes the type of [Some e], and the
   copy [t'] that of [h :: t]. [None] gets that type by type-directed
   disambiguation when a [None] of another type is in scope, which the source
   does not do, so the guard turns off the warnings of disambiguation. *)
let none ~loc ~module_name ~index value =
  [%expr
    if Stdlib.not [%e armed ~loc ~module_name index] then [%e value]
    else None [@ocaml.warning "-18-41-42"]]

(* [t'] is [t] as the source wrote it, without guards: when [t'] runs, its own
   site is the armed one. Its locations are ghost, as generated code has, so
   that no two nodes share a location and the coverage rewriter gives it no
   point. It takes the attributes of [h :: t], so that a warning attribute of
   the source covers it too. *)
let ghost =
  object
    inherit Ast_traverse.map
    method! location loc = { loc with loc_ghost = true }
  end

let tail ~loc ~module_name ~index e value t =
  let copy = ghost#expression t in
  let copy =
    { copy with pexp_attributes = copy.pexp_attributes @ e.pexp_attributes }
  in
  [%expr
    if Stdlib.not [%e armed ~loc ~module_name index] then [%e value]
    else [%e copy]]

(* Traversal *)

(* [lazy] of a trivial syntactic value compiles as already forced, and a
   guard under it would change that. Coverage's predicate, verbatim. No guard
   weakens the generalization of a binding: every site but a literal, [Some e]
   and [h :: t] is an application, a condition or a statement. The guard of
   these three is an [if], which the type-checker counts as a syntactic value
   when its two arms are, whatever its condition. *)
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
  end_line : int;
  end_col : int;
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

    (* The expression whose children are being rewritten, with its context,
       which the arid rules of a literal read. *)
    val mutable parent = None

    (* Whether the code being rewritten runs when the module is initialized:
       outside every function, [lazy], method and functor. *)
    val mutable at_load = true

    (* Whether the code being rewritten is in the right-hand side of a
       [let rec], outside every function and [lazy]. Such an expression cannot
       be an [if] that reads a variable of the [let rec]. *)
    val mutable recursive = false

    (* Whether the code being rewritten is in the arguments of a logging
       call, or of [failwith] or [invalid_arg], outside every statement. *)
    val mutable logging = false
    val mutable message = false
    method sites = List.rev sites
    method pins = pins

    (* [within ~logging ~message f] is [f ()] with these two flags. *)
    method private within :
        'a. logging:bool -> message:bool -> (unit -> 'a) -> 'a =
      fun ~logging:l ~message:m f ->
        let outer = (logging, message) in
        logging <- l;
        message <- m;
        let result = f () in
        let l, m = outer in
        logging <- l;
        message <- m;
        result

    (* A statement acts on the state of the program, so the rules of a
       logging call and of a failure message do not reach into it. *)
    method private statement : 'a. (unit -> 'a) -> 'a =
      fun f -> self#within ~logging:false ~message:false f

    (* [arid ~branches mutant] tells that the syntax shows [mutant]
       equivalent to the original, or that it changes a log message or a
       failure message alone. [branches] tells that the site is the condition
       of an [if] whose two branches are one expression. *)
    method private arid ~branches (mutant : mutant) =
      logging
      || (message && (mutant.rewrite = "int" || mutant.rewrite = "bool"))
      ||
      match mutant.guard with
      | Operator (app, Replace _) -> is_zero app.right
      | Operator (app, Branch) -> is_pure app.left && same app.left app.right
      | Neg | Operator (_, (Negate | Swap)) -> branches
      | Literal _ | Nothing | Tail _ | Delete -> false

    (* [site e mutant ~dismissed] records the site of [e] and is its index.
       It is [None], with nothing recorded, for generated code and for a site
       whose identifier another one has, as a deriver's copy does. *)
    method private site e (mutant : mutant) ~dismissed =
      let start = e.pexp_loc.loc_start and stop = e.pexp_loc.loc_end in
      let line = start.pos_lnum and col = start.pos_cnum - start.pos_bol in
      let key = (line, col, mutant.rewrite) in
      if e.pexp_loc.loc_ghost || Hashtbl.mem seen key then None
      else begin
        let index = Hashtbl.length seen in
        Hashtbl.add seen key ();
        let site =
          {
            line;
            col;
            end_line = stop.pos_lnum;
            end_col = stop.pos_cnum - stop.pos_bol;
            rewrite = mutant.rewrite;
            before = render e;
            after = mutant.after;
            dismissed;
          }
        in
        sites <- site :: sites;
        Some index
      end

    (* The mutant of a literal, when no arid rule drops it. Neither rewrite
       has a site that runs when the module is initialized, before any test,
       where no run can judge it. [int] skips a constant whose nudge is ROR's
       own boundary move, an operand of [+] or [-], which AOR moves, and a
       [create] argument. [bool] flips a literal outside a boolean context,
       where [neg] already acts, and skips an OS flag. *)
    method private literal context e =
      let is_child arg = arg == e in
      let applied =
        Option.bind parent (fun (p, c) ->
            Option.map (fun a -> (p, c, a)) (application p))
      in
      let loc = e.pexp_loc in
      match e.pexp_desc with
      | Pexp_constant (Pconst_integer (text, suffix)) -> (
          match nudge text suffix with
          | None -> None
          | Some (direction, nudged) ->
              let arid =
                at_load
                || (match applied with
                  | Some (_, _, app) when app.name = "+" || app.name = "-" ->
                      true
                  | Some (_, c, app) when keeps Cmp && c <> Ordinary ->
                      boundary_move ~constant_right:(is_child app.right)
                        app.name
                      = Some direction
                  | Some _ | None -> false)
                ||
                match parent with
                | Some ({ pexp_desc = Pexp_apply (fn, args); _ }, _) ->
                    is_create fn && List.exists (fun (_, a) -> is_child a) args
                | Some _ | None -> false
              in
              if arid then None
              else
                let replacement =
                  pexp_constant ~loc (Pconst_integer (nudged, suffix))
                in
                Some
                  {
                    guard = Literal replacement;
                    rewrite = "int";
                    after = render replacement;
                  })
      | Pexp_construct ({ txt = Lident (("true" | "false") as b); _ }, None)
        when context = Ordinary ->
          let os_flag =
            match parent with
            | Some ({ pexp_desc = Pexp_apply (_, args); _ }, _) ->
                List.exists
                  (fun (label, a) ->
                    is_child a
                    &&
                    match label with
                    | Labelled l | Optional l -> List.mem l os_flags
                    | Nolabel -> false)
                  args
            | Some _ | None -> false
          in
          if at_load || os_flag then None
          else
            let flipped = if String.equal b "true" then "false" else "true" in
            let replacement =
              pexp_construct ~loc { txt = Lident flipped; loc } None
            in
            Some
              { guard = Literal replacement; rewrite = "bool"; after = flipped }
      | _ -> None

    (* The mutant of [Some e] or [h :: t]. Code that runs when the module is
       initialized and the right-hand side of a [let rec] have none. *)
    method private value e =
      if (not (keeps Ret)) || at_load || recursive then None
      else
        match (e.pexp_desc, cons e) with
        | Pexp_construct ({ txt = Lident "Some"; _ }, Some _), _ ->
            Some { guard = Nothing; rewrite = "none"; after = "None" }
        | _, Some (_, t) ->
            Some { guard = Tail t; rewrite = "tail"; after = render t }
        | _, None -> None

    (* [chained] marks the left operand of a site that applies the same
       operator: a chain of one operator carries one mutant, and reading it
       from the tree keeps a bracket from changing the count. A dismissal
       leaves [e] as written, and an arid site ends the chain. [branches] is
       for the condition of an [if], as [arid] reads it. [parent] and
       [at_load] hold for the children of [e] while they are rewritten. *)
    method private mutate ?chained ?branches context e =
      let outer = (parent, at_load, recursive) in
      let mutant =
        match mutant ~keeps context e with
        | Some _ as mutant -> mutant
        | None -> (
            match self#literal context e with
            | Some _ as mutant -> mutant
            | None -> self#value e)
      in
      parent <- Some (e, context);
      (match e.pexp_desc with
      | Pexp_function _ | Pexp_lazy _ ->
          at_load <- false;
          recursive <- false
      | Pexp_poly _ | Pexp_object _ | Pexp_newtype _ -> at_load <- false
      | _ -> ());
      let rewritten = self#rewrite ?chained ?branches context e mutant in
      let p, l, r = outer in
      parent <- p;
      at_load <- l;
      recursive <- r;
      rewritten

    (* [recursively f] is [f ()] in the right-hand side of a [let rec]. *)
    method private recursively : 'a. (unit -> 'a) -> 'a =
      fun f ->
        let outer = recursive in
        recursive <- true;
        let result = f () in
        recursive <- outer;
        result

    method private rewrite ?(chained = false) ?(branches = false) context e
        mutant =
      let off = off_reason e.pexp_attributes in
      if is_opaque e then e
      else
        match (off, mutant) with
        | Some _, None -> e
        | Some reason, Some mutant ->
            if not chained then
              ignore (self#site e mutant ~dismissed:(Some reason));
            e
        | None, None -> self#descend e
        | None, Some mutant ->
            let arid = self#arid ~branches mutant in
            let index =
              if chained || arid then None
              else self#site e mutant ~dismissed:None
            in
            self#guard ~chain:(not arid) e mutant index

    method private guard ~chain e mutant index =
      let loc = { e.pexp_loc with loc_ghost = true } in
      match mutant.guard with
      | Delete -> e (* [descend] guards a statement *)
      | Literal replacement -> (
          match index with
          | None -> e
          | Some index ->
              [%expr
                if [%e armed ~loc ~module_name index] then
                  [%e { replacement with pexp_loc = loc }]
                else [%e e]])
      | Nothing -> (
          let value = self#descend e in
          match index with
          | None -> value
          | Some index -> none ~loc ~module_name ~index value)
      | Tail t -> (
          let value = self#chain e in
          match index with
          | None -> value
          | Some index -> tail ~loc ~module_name ~index e value t)
      | Neg -> (
          let value = self#descend e in
          match index with
          | None -> value
          | Some index -> negation ~loc ~module_name ~index value)
      | Operator (app, guard) -> (
          let context =
            match guard with
            | Branch -> Boolean
            | Negate | Swap | Replace _ -> Ordinary
          in
          let chained = chain && applies app.name app.left in
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

    (* [chain e] rewrites the head and the tail of [h :: t]. A tail that is
       [(::)] too, as in [a :: b :: t] and in a list literal, continues the
       chain and carries no site. Each [tail] guard holds a copy of its tail,
       so a site at each [(::)] would make the code grow as the square of the
       length of the chain. A dismissal of a tail leaves it as written. *)
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
          let branches =
            match else_ with Some else_ -> same then_ else_ | None -> false
          in
          {
            e with
            pexp_desc =
              Pexp_ifthenelse
                ( self#mutate ~branches Condition condition,
                  self#expression then_,
                  Option.map self#expression else_ );
          }
      | Pexp_while (condition, body) ->
          {
            e with
            pexp_desc =
              Pexp_while (self#mutate Condition condition, self#expression body);
          }
      | Pexp_sequence (first, rest) -> (
          (* [del] drops a statement: [(if armed then () else (e1; ())); e2],
             where [e1; ()] types [e1] as the statement it was. *)
          let deletable =
            (not at_load)
            && (not (is_opaque first))
            && (not (is_release first))
            &&
            match first.pexp_desc with
            | Pexp_construct ({ txt = Lident "()"; _ }, None) -> false
            | _ -> true
          in
          let off = off_reason first.pexp_attributes in
          let index, first' =
            self#statement (fun () ->
                let index =
                  if not deletable then None
                  else
                    let mutant =
                      { guard = Delete; rewrite = "del"; after = "()" }
                    in
                    match self#site first mutant ~dismissed:off with
                    | Some _ when Option.is_some off -> None
                    | index -> index
                in
                (index, self#expression first))
          in
          let rest' = self#expression rest in
          match index with
          | None -> { e with pexp_desc = Pexp_sequence (first', rest') }
          | Some index ->
              let loc = { first.pexp_loc with loc_ghost = true } in
              let dropped =
                [%expr
                  if [%e armed ~loc ~module_name index] then ()
                  else (
                    [%e first'];
                    ())]
              in
              { e with pexp_desc = Pexp_sequence (dropped, rest') })
      | Pexp_apply (operator, [ (Nolabel, left); (Nolabel, right) ])
        when is_connective ~keeps e ->
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
      | Pexp_let (Nonrecursive, bindings, body) ->
          let binding vb =
            if is_unit_binding vb then
              self#statement (fun () -> self#value_binding vb)
            else self#value_binding vb
          in
          let bindings = List.map binding bindings in
          {
            e with
            pexp_desc = Pexp_let (Nonrecursive, bindings, self#expression body);
          }
      | Pexp_let (Recursive, bindings, body) ->
          let bindings =
            self#recursively (fun () -> List.map self#value_binding bindings)
          in
          {
            e with
            pexp_desc = Pexp_let (Recursive, bindings, self#expression body);
          }
      | Pexp_apply _ when calls is_logger e ->
          self#within ~logging:true ~message (fun () -> super#expression e)
      | Pexp_apply _ when keeps Message && calls is_failure e ->
          self#within ~logging ~message:true (fun () -> super#expression e)
      | _ -> super#expression e

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

    (* A functor's body and a class run when they are applied or
       instantiated, not when the module is initialized. *)
    method! module_expr me =
      match me.pmod_desc with
      | Pmod_functor _ ->
          let outer = at_load in
          at_load <- false;
          let me = super#module_expr me in
          at_load <- outer;
          me
      | _ -> super#module_expr me

    method! class_expr ce =
      let outer = at_load in
      at_load <- false;
      let ce =
        match ce.pcl_desc with
        | Pcl_let (Recursive, bindings, body) ->
            let bindings =
              self#recursively (fun () -> List.map self#value_binding bindings)
            in
            {
              ce with
              pcl_desc = Pcl_let (Recursive, bindings, self#class_expr body);
            }
        | _ -> super#class_expr ce
      in
      at_load <- outer;
      ce

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
          let bindings () = List.map binding bindings in
          let bindings =
            match rec_flag with
            | Recursive -> self#recursively bindings
            | Nonrecursive -> bindings ()
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
  let site { line; col; end_line; end_col; rewrite; before; after; dismissed } =
    let dismissed =
      match dismissed with
      | None -> [%expr None]
      | Some reason -> [%expr Some [%e estring ~loc reason]]
    in
    [%expr
      {
        line = [%e eint ~loc line];
        col = [%e eint ~loc col];
        end_line = [%e eint ~loc end_line];
        end_col = [%e eint ~loc end_col];
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
        end_line : int;
        end_col : int;
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

let transform_impl_file ctxt ast =
  let file = Expansion_context.Base.input_name ctxt in
  if
    List.mem file always_ignore_paths
    || List.mem (Filename.basename file) always_ignore_basenames
    || excludes_file ast
  then ast
  else
    let module_name = generated_module_name file in
    let instrumenter =
      new instrumenter ~keeps:(kept_families ast) ~module_name
    in
    let instrumented = instrumenter#structure ast in
    match instrumenter#sites with
    | [] -> ast
    | sites ->
        runtime_initialization ~file ~module_name ~sites ~pins:instrumenter#pins
        @ instrumented
