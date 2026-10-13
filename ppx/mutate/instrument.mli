(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** The mutation rewriter.

    {!transform_impl_file} maps the parsetree of an implementation file to the
    same parsetree with each {{!section-sites}site} replaced by a guard. The
    disarmed arm of a guard is the original expression and its armed arm is the
    mutant. It prepends a {{!section-generated}generated module} that registers
    the site table of the file with [Windtrap_runtime.Mutate] and binds the
    guard closure that the registration returns. The
    {{!section-dismissal}dismissal attributes} switch the rewriting off for an
    expression, a binding, a region or a file.

    Every mutant of a project is compiled into one binary, in which the runtime
    arms at most one. A mutant changes meaning only in the process that armed
    it. That process is a forked child of the [--mutate] loop, or the run itself
    under [--arm]. This rewriter's part is that a program with no mutant armed
    computes what the uninstrumented one does. A guard evaluates each operand
    once and in the order of the original application, a tail call stays a tail
    call, and a [lazy] is compiled as it was. *)

(** {1:law The emission law}

    Every arm of a guard must be well typed without type information. It must
    mention only identifiers that the original expression already holds, and
    names qualified by [Stdlib]. All the mutants share one binary, so an arm
    that does not type-check breaks the build of the whole project. Whoever adds
    an operator must keep the law.

    [ari] is the one exception, because [a + b] cannot become [a - b] without
    naming [-]. A file that rebinds an operator where the rewriter can see it
    thus loses the whole family of that operator: [ari] for [+], [-], [+.] and
    [-.], [cmp] for the six comparisons, and [con] for [&&] and [||]. [neg]
    names [Stdlib.not] alone and is never lost. A rebinding is seen when a
    variable pattern anywhere in the file, or a value description such as an
    [external], bears the name of the operator. What an [open] brings into scope
    is not seen. When such an operator does not fit an arm, the file fails to
    compile under instrumentation, with the error at the expression in the
    source, and [[@@@mutate exclude_file]] is the way out.

    [arm] names no value, and [call] names [Stdlib.not] alone. Their
    constructors stand where the type-checker expects the predefined type:
    [true] and [false] of [arm] where it expects [bool], and [()] of [call]
    where it expects [unit]. A file that declares one of these constructors, in
    a type or as an extension constructor, loses the family all the same. A
    constructor [true] or [false] of the file makes warning 42 report the
    constructors of [arm], and the pattern of [let () = e] then names the
    constructor [()] of the file. A constructor that an [open] brings into scope
    is not seen.

    [lit] and [ret] name no value, and [tail] names [Stdlib.not] alone. The
    constructors of [flip] stand where the type of the original [true] or
    [false] is expected, and the [None] of [none] where the type of the original
    [Some e] is expected. The armed arm of [tail] is a copy of [t] in [h :: t],
    and gets the type of the original. A file that declares a constructor [true]
    or [false] loses the [flip] rewrite of [lit], and a file that declares a
    constructor [Some], [None] or [(::)] loses [ret]. A constructor that an
    [open] or type-directed disambiguation takes from another module is not
    seen. A [Some e] of a type that has no constructor [None], or an [h :: t]
    whose [t] has another type, then fails to compile under instrumentation, and
    [[@mutate off]] on the expression is the way out. *)

(** {1:sites Sites}

    A site is an expression or a case that carries one mutant. *)

(** {2:operators Operators}

    Each operator rewrites its sites in one way, and the name of the rewrite
    says what replaces the original. The sites of [cmp], [con] and [ari] are
    applications of a bare operator to two unlabelled arguments. A qualified
    spelling such as [Float.( < )], a labelled application and a partial one are
    not sites.
    - [neg] negates a condition, under the name [not]. Its sites are the
      condition of an [if] or of a [while] and the guard of a case, when the
      expression is neither a comparison nor a connective.
    - [cmp] moves a comparison by one boundary. [<] becomes [<=] under the name
      [le], [<=] becomes [<] under [lt], [>] becomes [>=] under [ge], [>=]
      becomes [>] under [gt], [=] becomes [<>] under [neq], and [<>] becomes [=]
      under [eq]. Its sites lie in a boolean context alone.
    - [con] swaps [&&] and [||], under the names [or] and [and], and keeps the
      short-circuit evaluation. The deprecated [&] and [or] are not sites.
    - [ari] swaps [+] and [-] under the names [sub] and [add], and [+.] and [-.]
      under [fsub] and [fadd].

    A boolean context is the condition of an [if] or of a [while], the guard of
    a case, or a direct operand of [&&] or [||] in a file that keeps the [con]
    family. It does not reach through a sequence, a [let], a type constraint or
    [not], so the comparison of [let ok = a < b] has no mutant. [con] and [ari]
    have sites in every context.

    The armed arm of an ordering rewrite applies the original operator to the
    swapped operands under [Stdlib.not], so [a < b] armed is [not (b < a)]. On
    floats this is the [after] text of the mutant except when an operand is NaN.
*)

(** {2:control Arms and calls}

    Two families change the control flow, and each has one rewrite.
    - [arm] drops a case of a [match], of a [function] or of a [try], under the
      name [drop]. When the mutant is armed, the case does not match, so a value
      goes to the next case that matches it or raises [Match_failure], and an
      exception goes on to the next handler.
    - [call] skips an application, under the name [skip]. Its sites are the left
      operand of a sequence [e1; e2] and the expression of [let () = e in body],
      when that expression is an application. When the mutant is armed, the
      application and its arguments are not evaluated. A [let () = e] that is a
      structure item has no site, because module initialization alone runs it.
      An application of a name that starts with [___windtrap_] is generated
      code, and is no site. The exception is the wrapper of a call that the
      coverage rewriter adds, when it runs first (see {!section-generated}).

    These cases are not [arm] sites:
    - Each case of a [match] or a [function] that has a refutation case, as
      [| _ -> .]. A guard on a case before the refutation case makes the
      refutation case fail to type.
    - A case whose pattern matches a value and an exception, as
      [| None | exception Not_found]. The compiler refuses a guard on it.
    - The case of a [match] or a [function] that a value reaches, when no other
      case of it does. Without it, every value raises [Match_failure]. An
      exception case and each case of a [try] are sites.
    - An effect case of OCaml 5.3, as [| effect Ask, k]. It matches no value and
      no exception, and the family drops the cases of values and of exceptions
      alone.

    A case becomes [p when (if armed then false else true) -> e], and a case
    with a guard becomes [p when (if armed then false else g) -> e]. The guard
    [g] is thus evaluated after the armed flag, and as often as before. The
    type-checker reads the branches of an [if] and not its condition, so a match
    whose cases are syntactic values stays one, and its binding generalizes as
    before. A guarded case does not count for exhaustiveness, so a [match] or a
    [function] that has an [arm] guard gets the attribute
    [[@ocaml.warning "-8-57"]]. Warning 57 examines a guard against the earlier
    cases without a guard alone. An [arm] guard on an earlier case can thus make
    an or-pattern variable of a later guarded case ambiguous. A [try] that has
    an [arm] guard gets [[@ocaml.warning "-57"]] for the same reason.

    When a case of a value in a [match] or a [function] gets an [arm] guard,
    each other case of a value that has no guard gets the guard [true]. If not,
    the cases without a guard can cover every value, and the type-checker then
    finds the match total. After an [arm] guard fails, the compiled match can
    read a mutable field again, and then finds the match partial (74). The
    compiler gives warning 74 after the type-checker, so no attribute disables
    it. A case that matches a value and an exception cannot have a guard. When
    such cases cover every value, warning 74 can thus still occur.

    The [call] guard of a sequence is [if Stdlib.not armed then (e1; ())]. The
    application stays the left operand of a sequence, so it types as before,
    under [-strict-sequence] or not. The guard of [let () = e] is
    [if Stdlib.not armed then e], where [e] gets the expected type [unit].

    The backend flags [-no-arm] and [-no-call] switch these two families off, as
    in [(instrumentation (backend ppx_windtrap.mutate -no-arm))].
    {!section-values} gives the flags of [lit] and [ret]. *)

(** {2:values Literals and values}

    Two families change a value, and each has more than one rewrite.
    - [lit] changes a literal. An integer literal becomes its successor, with
      its suffix, under the name [one] for [0] and [inc] for the others. The
      successor of the greatest integer is the least one, as the addition of the
      type gives. A float literal other than zero becomes [0.] under [zero], and
      a zero becomes [1.] under [one]. [true] and [false] swap under [flip],
      except in a condition, where [neg] gives the same mutant. A string, a
      character and a literal with a suffix that the compiler does not know are
      no sites. An integer literal that its type cannot hold is no site, so that
      the compiler reports the error.
    - [ret] removes a part of a value. [Some e] becomes [None] under [none], and
      [h :: t] becomes [t] under [tail]. A list literal [[a; b]] is one site, at
      its bracket, and becomes [[b]], because the parser gives the other [(::)]
      of the literal ghost locations. In a chain of [(::)], as [a :: b :: t],
      the outermost [(::)] alone is a site, and becomes [b :: t]. A qualified
      constructor, as [Option.Some], is no site.

    The guard of [lit] is [if armed then c' else c], and that of [none] is
    [if armed then None else Some e], so [e] is not evaluated when the mutant is
    armed. The guard of [tail] is [if Stdlib.not armed then h :: t else t'],
    where [t'] is a copy of [t] as the source wrote it. [t] is thus evaluated
    once, and [h] is not evaluated when the mutant is armed. The type-checker
    reads the branches of an [if] in order, so [h] gives its type to [t] as in
    the original, and [t'] gets the type of the original. The sites inside [t']
    have no guard, because when [t'] runs, its own site is the armed one. The
    type-checker does not read the condition of an [if] when it decides if an
    expression is a syntactic value, so a binding of a literal, of [Some v] or
    of [h :: t] still generalizes.

    The guard of [tail] holds a copy of [t], and its text holds the text of [t].
    A site at each [(::)] of a chain would thus make the code grow as the square
    of the length of the chain.

    The right-hand side of a [let rec] cannot be an [if] that reads a variable
    of the [let rec]. Thus an expression in such a right-hand side has no [ret]
    site, except in a function or a [lazy] body inside it. This is true for a
    [let rec] of a structure, of an expression and of a class.

    [lit] is off by default, because a program has many literals. The backend
    flag [-lit] switches it on, and [-no-ret] switches [ret] off. *)

(** {2:placement Placement}

    - An expression carries at most one mutant, and [neg] and [call] come last.
      A condition that is a comparison carries [cmp], and one that is a
      connective carries [con].
    - No guard duplicates another site. A connective with a connective for an
      operand carries no mutant, neither [con] nor [neg], so [a && b && c]
      mutates [b && c] alone. Its operands are boolean contexts all the same.
    - In a file that lost the [con] or the [cmp] family, a condition of that
      family is no longer recognized as one, and carries [neg].
    - An application of an operator that carries a mutant carries no [call], and
      a connective with a connective for an operand carries none either. Every
      other application in the place of a [call] site carries [call].
    - A case is no expression. Its [arm] mutant does not change the mutants of
      its pattern, its guard and its body.
    - In a chain of one arithmetic operator, as [a + b + c], the outermost
      application alone is a site. The rule reads the tree and not the layout,
      so [(a + b) + c] and [f (a + b + c)] carry one mutant too. [a + b - c]
      carries two, because [sub] and [add] are two rewrites, and so does
      [a + b + (c + d)].
    - A literal, [Some e] and [h :: t] carry no other mutant.
    - A guard binds its operands under the names [__windtrap_mut_<i>_<role>],
      where [<i>] is the index of the site and [<role>] is [p], [l] or [r]. *)

(** {2:exclusions Code that is never mutated}

    - An [assert], with everything under it.
    - A [lazy] whose body is a trivial syntactic value, with everything under
      it. Such a value is a function, an identifier, a constant or a constant
      constructor, with or without a type constraint or a coercion.
      [lazy (fun x -> x + 1)] carries no mutant.
    - The payloads of attributes and of extension nodes.
    - The inline tests of a file, which are test code; the rest of the file is
      mutated. An inline test is an extension node such as [let%test] or
      [module%test], which a driver without ppx_windtrap leaves in place, or the
      items that ppx_windtrap expands it into, each of which carries the
      attribute [[@@windtrap.test]]. A [let] or [module] item that carries it is
      left as written, the helpers inside a [module%test] included.
    - Generated code, which is a site at a ghost location.
    - A site whose line, column and rewrite an earlier site of the file already
      has, which happens in the code of a deriver. The first one keeps the
      identifier, which must name one site.

    The code that runs when a module is initialized is mutated like any other,
    so a top-level [let origin = 1 + 2] carries a site. The [--mutate] loop
    lists a site that ran outside tests alone as evaluated outside tests. *)

(** {1:dismissal Dismissal attributes}

    The attribute is named [mutate] and follows the grammar of the [coverage]
    attribute of the coverage rewriter. Its payload is [off], [on] or
    [exclude_file], and [off] alone takes a reason, as one string literal:
    [[@mutate off "reason"]]. The reason is for the reader of the source. No
    report prints it, and it is read back through
    [Windtrap_runtime.Mutate.catalogue] alone.
    - [[@mutate off]] on an expression leaves the expression as written, with
      everything inside it. When the expression is itself a site, the site is
      recorded in the table as dismissed, with the reason, or with [""] when
      none is given. It takes an index and no guard. When the expression is no
      site, as a [match], nothing is recorded. The sites inside the expression
      are never recorded.
    - [[@@mutate off]] leaves as written a value binding at the top level of a
      structure, and a module binding, recursive or not. On a [let … in] binding
      and on any other structure item it is ignored and its payload is not
      checked. [[@mutate off]] on the bound expression covers that case.
    - [[@@@mutate off]] opens a region of structure items that are left as
      written, and [[@@@mutate on]] closes it. A region belongs to the structure
      that it opens in. A nested structure inherits it, and the end of a nested
      structure restores the setting of the outer one. A region that is never
      closed runs to the end of its structure.
    - [[@@@mutate exclude_file]] among the top-level items of a file excludes
      the file.

    The last three record no site, and the reason of a [[@@mutate off]] or of a
    [[@@@mutate off]] is accepted and dropped.

    [[@mutate off]] dismisses every mutant of its expression, and keeps that
    meaning in any later version that gives an expression more mutants. A
    payload that names a rewrite, as [[@mutate off gt "reason"]], is refused.

    After parameters, as in [let f x = function[@mutate off "reason"] ...], the
    parser puts the attributes of [function] on its cases. There,
    [[@mutate off]] leaves the cases as written, with everything inside them,
    and records nothing. The parameters keep their sites.

    A case is no expression, so its [arm] site is dismissed on its pattern, as
    [| (Some x [@mutate off "reason"]) -> e]. The site is then recorded as
    dismissed, and the pattern has no other site. The guard and the body of the
    case keep their mutants. The attribute must be on the whole pattern. The
    parser puts the attribute of [| A | B [@mutate off "reason"]] on [B], and
    that of [| a, b [@mutate off "reason"]] on [b]. Thus a [mutate] attribute
    inside the pattern of an [arm] site is refused, and an or-pattern or a tuple
    takes it in brackets, as [| (A | B) [@mutate off "reason"]]. *)

(** {1:identification Identification}

    The identifier of a mutant is [<file>:<line>:<col>:<rewrite>], as
    [lib/calc.ml:9:12:add]. The rewriter records the last three and the runtime
    joins the file. [<line>] is the one-based line of the first byte of the
    site, and [<col>] is the zero-based column of that byte, counted in bytes.
    The first byte of an [arm] site is the first byte of the pattern of its
    case. A site in brackets starts at its bracket, so bracketing a site, as
    [[@mutate off]] on an infix expression or on a pattern requires, moves its
    column by one. Two sites may share a line and a column under two rewrites.

    A site is numbered by the order of its allocation, from [0], and the numbers
    are local to the file. That order is the traversal's and not the source's. A
    site comes before the sites inside its operands, and the operands of a
    mutated operator come left to right. The else branch of an [if] comes before
    its then branch, and both before its condition, and the body of a [while]
    comes before its condition. The left operand of a sequence comes before the
    right one, and the bindings of a [let] come before its body. The cases of a
    [match] or a [try] come after its scrutinee or its body, in the order of the
    source. An [arm] site comes before the sites of its case.

    The [before] and [after] texts of a site are printed from the parsetree and
    never cut out of the source. The attributes of the site are left out, and
    each run of blanks becomes one space, inside a string literal too, so a text
    is one line. The brackets are those of the printer: [a + b + c] is recorded
    as [(a + b) + c], and its mutant as [(a + b) - c].

    The texts of an [arm] site give the pattern and the guard of its case, and
    [...] stands for the body: [| Some x when x > 0 -> ...] before and
    [| Some x when false -> ...] after. The [after] text of a [call] site is
    [()], that of a [none] site is [None], and that of a [tail] site is [t]. The
    printer gives a list as a list literal where it can, so [x :: [y]] is
    recorded as [[x; y]], and a negative literal in brackets, as [(-1)].

    ppxlib encodes a construct that its parsetree does not have, as a labeled
    tuple of OCaml 5.4, as an extension node [[%ppxlib.migration.<name> ...]]. A
    text that holds such a node is printed by the printer of the compiler, which
    spells the construct as the source does, as [| (~x:0, ~y) -> ...]. *)

(** {1:generated Generated code}

    The rewriter prepends three structure items, in this order: a stop comment
    [[@@@ocaml.text "/*"]], the module [Windtrap_mut___<name>], and a second
    stop comment. [<name>] is the input name of the file, as the driver gives
    it, with every byte other than an ASCII letter, a digit or [_] replaced by
    [___]. The module is never opened, and a guard calls
    [Windtrap_mut___<name>.___windtrap_armed___ i], which is [true] iff the site
    [i] is the armed one.

    The module holds, in this order:
    - [type site = Windtrap_runtime.Mutate.site = { … }], the record of the
      runtime with its six fields spelled out. A runtime whose record differs
      thus fails to compile against the generated code.
    - [type 'a operands = 'a * 'a], only in a file that holds the guard of an
      ordering rewrite, which annotates its pair of operands with it.
    - [___windtrap_armed___], bound to
      [Windtrap_runtime.Mutate.register ~file ~sites]. The call is made once,
      when the module is initialized, within the preconditions of [register].
      [file] is the input name and [sites] is the table in index order.

    Every generated node has a ghost location, with two exceptions. The disarmed
    arm of an ordering or [ari] guard is the original application rebuilt over
    the binders, and keeps its location and its attributes. A [match], a
    [function] or a [try] with an [arm] guard keeps its location, and the
    generated [[@ocaml.warning]] comes before its attributes. After parameters,
    as in [fun x -> function[@a] ...], the parser puts the attributes of
    [function] on its cases, and the generated attribute also comes before them.
    The compiler applies the attributes of a node from the last to the first, so
    a warning attribute of the user cannot turn warnings 8 and 57 on again. The
    copy [t'] of a [tail] guard is generated code too: each of its locations is
    ghost, so that no two nodes share a location.

    In the driver that dune builds for a stanza naming both backends this
    rewriter runs first, so its sites are those stated here and the coverage
    rewriter receives its guards. When the coverage rewriter ran on the file
    first, which is the order of a driver that links this library before
    [ppx_windtrap.coverage], the file holds its visits:
    - [a || b] reaches this rewriter as the [if] of that rewriter. It carries no
      [con] mutant, and an operand that became a condition is mutated as one.
    - the [before] and [after] texts of a site hold the visits inside it, as
      [___windtrap_post_visit___ 0 (f x)] for [f x].
    - a visit that is the left operand of a sequence is no [call] site.
    - the wrapper [___windtrap_post_visit___ n e] of an application [e] is the
      [call] site of [e], and its guard skips the visit with [e].
    - a [[@mutate off]] on [e] applies to its wrapper, so it dismisses the site
      of the wrapper in each context, as the [neg] site of a condition. The
      texts of the wrapper leave out the attributes of [e].

    The mutants of such a file are not those of the file under this rewriter
    alone. *)

(** {1:rewriting Rewriting} *)

val transform_impl_file :
  ?arm:bool ->
  ?call:bool ->
  ?lit:bool ->
  ?ret:bool ->
  Ppxlib.Expansion_context.Base.t ->
  Ppxlib.Parsetree.structure ->
  Ppxlib.Parsetree.structure
(** [transform_impl_file ~arm ~call ~lit ~ret ctxt ast] is [ast] with a guard at
    each site and the {{!section-generated}generated module} prepended. [arm],
    [call], [lit] and [ret] keep the family of that name. [lit] defaults to
    [false], and the others to [true]. [ctxt] is read for the input name of the
    file alone.

    The result is [ast] itself in three cases:
    - [ast] has a top-level [[@@@mutate exclude_file]].
    - The input name is [//toplevel//] or [(stdin)], or its base name is
      [.ocamlinit] or [topfind].
    - No site was recorded. A dismissed site is a recorded one, so a file whose
      every site is dismissed is registered, by a module that no guard refers
      to.

    The rewriter reads the [mutate] attributes of the expressions that it
    traverses, of the cases of a [function] after parameters, of the patterns of
    the [arm] sites and of their sub-patterns, of the value bindings at the top
    level of a structure and of module bindings, and those that float in a
    structure. An attribute anywhere else, or inside an expression that is never
    mutated or is dismissed, is never examined.

    Raises a ppxlib located error, which the driver reports as a compile error
    at the attribute, if an attribute that the rewriter reads:
    - has a payload other than [off], [off] with one string literal, [on] or
      [exclude_file].
    - is [on] or [exclude_file] on an expression, on the cases of a [function]
      after parameters, on a pattern or on a binding.
    - is on a sub-pattern of the pattern of an [arm] site, as on the last
      alternative of an or-pattern.
    - is [exclude_file] floating inside a nested structure.
    - is [[@@@mutate off]] inside a region, or [[@@@mutate on]] outside one.

    No other input raises. *)
