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

    The arms of [int] are constants, and [del]'s armed arm is [()]. [bool] names
    the other of [true] and [false], which resolves as the original does unless
    a type in scope redeclares one of the two constructors without the other.

    [none] names the constructor [None] unqualified, after the original
    [Some e], so [None] gets the type of the original. When a [None] of another
    type is in scope, [None] gets that type by type-directed disambiguation, so
    it carries [[@ocaml.warning "-18-41-42"]]. The armed arm of [tail] is a copy
    of [t] in [h :: t], and gets the type of the original. A file that declares
    a constructor [Some], [None] or [(::)], in a type or as an extension
    constructor, loses the two rewrites. A constructor that an [open] or
    type-directed disambiguation takes from another module is not seen. Thus a
    [Some e] of a type that has no constructor [None], or an [h :: t] whose [t]
    has another type, fails to compile under instrumentation. [[@mutate off]] on
    the expression is the way out.

    [ari] is the one exception, because [a + b] cannot become [a - b] without
    naming [-]. A file that rebinds an operator where the rewriter can see it
    thus loses the whole family of that operator: [ari] for [+], [-], [+.] and
    [-.], [cmp] for the six comparisons, and [con] for [&&] and [||]. [neg]
    names [Stdlib.not] alone and is never lost. A rebinding is seen when a
    variable pattern anywhere in the file, or a value description such as an
    [external], bears the name of the operator. What an [open] brings into scope
    is not seen. When such an operator does not fit an arm, the file fails to
    compile under instrumentation, with the error at the expression in the
    source, and [[@@@mutate exclude_file]] is the way out. *)

(** {1:sites Sites}

    A site is an expression that carries one mutant. *)

(** {2:operators Operators}

    Each operator rewrites its sites in one way, and the name of the rewrite
    says what replaces the original. The sites of [cmp], [con] and [ari] are
    applications of a bare operator to two unlabelled arguments. A qualified
    spelling such as [Float.( < )], a labelled application and a partial one are
    not sites.
    - [neg] negates a condition, under the name [not]. Its sites are the
      condition of an [if] or of a [while] and the guard of an arm, when the
      expression is neither a comparison nor a connective.
    - [cmp] moves a comparison by one boundary. [<] becomes [<=] under the name
      [le], [<=] becomes [<] under [lt], [>] becomes [>=] under [ge], [>=]
      becomes [>] under [gt], [=] becomes [<>] under [neq], and [<>] becomes [=]
      under [eq]. Its sites lie in a boolean context alone.
    - [con] swaps [&&] and [||], under the names [or] and [and], and keeps the
      short-circuit evaluation. The deprecated [&] and [or] are not sites.
    - [ari] swaps [+] and [-] under the names [sub] and [add], and [+.] and [-.]
      under [fsub] and [fadd].
    - [del] drops a statement: [e1] in [e1; e2] does not run, under the name
      [del]. The guard is [(if armed then () else (e1; ())); e2], which types
      [e1] as the statement that it was. [()] and an [assert] are no statement
      it drops, and neither is the value [e2] of a sequence.
    - [int] nudges an integer literal by one in the type that its suffix gives,
      under the name [int]: [1] becomes [0], and any other [n] becomes [n + 1].
      A literal whose nudge leaves its type, as [max_int], and a literal with a
      suffix other than [l], [L] or [n] are no sites.
    - [bool] flips [true] and [false], under the name [bool], outside a boolean
      context, where [neg] already acts.
    - [none] replaces [Some e] with [None], under the name [none].
    - [tail] replaces [h :: t] with [t], under the name [tail]. A list literal
      [[a; b]] is one site, at its bracket, and becomes [[b]]. In a chain of
      [(::)], as [a :: b :: t], the outermost [(::)] alone is a site, and
      becomes [b :: t]. A qualified constructor, as [Option.Some], is no site.

    The guard of [int] and of [bool] is [if armed then n' else n], an [if] whose
    two arms are constants. The guard of [none] is
    [if Stdlib.not armed then Some e else None], so [e] does not run when the
    mutant is armed. The guard of [tail] is
    [if Stdlib.not armed then h :: t else t'], where [t'] is a copy of [t] as
    the source wrote it, with no guard inside it. [t'] also has the attributes
    of [h :: t], so that a warning attribute of the source covers it. Thus [t]
    runs once, and [h] does not run when the mutant is armed. The type-checker
    counts an [if] as a syntactic value when its two arms are one, whatever its
    condition, so a binding that generalizes still does.

    The guard of [tail] holds a copy of [t]. A site at each [(::)] of a chain
    would thus make the code grow as the square of the length of the chain.

    A boolean context is the condition of an [if] or of a [while], the guard of
    an arm, or a direct operand of [&&] or [||] in a file that keeps the [con]
    family. It does not reach through a sequence, a [let], a type constraint or
    [not], so the comparison of [let ok = a < b] has no mutant. [con] and [ari]
    have sites in every context.

    The armed arm of an ordering rewrite applies the original operator to the
    swapped operands under [Stdlib.not], so [a < b] armed is [not (b < a)]. On
    floats this is the [after] text of the mutant except when an operand is NaN.
*)

(** {2:arid Arid code}

    Some sites carry no mutant, because no test should tell the mutant from the
    original, or no test can run it. An arid site has no record, no index and no
    guard, and the sites inside it keep their mutants:
    - [del] skips a resource release: a call of a function named [close],
      [close_in], [close_out], [close_noerr], [close_in_noerr],
      [close_out_noerr] or [closedir], qualified or not, also under [ignore] or
      as the body of a [try].
    - [int] skips a literal that is an operand of a bare [+] or [-], which [ari]
      moves already, and an argument of a function whose name ends in [create],
      as [Hashtbl.create 16], which is a capacity.
    - [int] skips the constant of a comparison that carries [cmp] when the nudge
      is the boundary move of [cmp]: up for [x < c] and [x >= c], down for
      [x <= c] and [x > c], and the mirror for a constant on the left. In
      [x < 0] the [0] is no site, since [x < 1] is [x <= 0], and in [x >= 1] the
      [1] is one.
    - [del], [int], [bool], [none] and [tail] skip code that runs when the
      module is initialized, before any test, so that no run can judge its
      mutant: code outside every function, [lazy], method, class and functor
      body, as in a top-level [let limit = 64] or [let () = setup (); main ()].
    - [none] and [tail] skip the right-hand side of a [let rec] outside every
      function and [lazy] in it, because that expression cannot be an [if] that
      reads a variable of the [let rec]. This applies to a [let rec] of a
      structure, of an expression and of a class.
    - [bool] skips the argument of a [~cloexec] or [?cloexec] label, an OS flag.
    - [ari] skips [x + 0] and [x - 0], where [0] is an integer literal without a
      suffix, as [0] or [0x0]. The two are equal on every [int]. [0 + x] keeps
      its mutant, and so does [x +. 0.], because [-0. +. 0.] is [0.] and
      [-0. -. 0.] is [-0.].
    - [con] skips [a && a] and [a || a] when the two operands are one expression
      and [a] is an identifier, a constructor without an argument, as [true], or
      a field of such an expression, with or without a type constraint. Such an
      operand gives one value each time and does nothing else.
    - [neg] and [cmp] skip the condition of [if c then e1 else e2] when [e1] and
      [e2] are one expression. [con] keeps its mutant there, because it also
      changes which operand runs.
    - Each rewrite skips the sites in the arguments of a logging function:
      [Logs.app], [Logs.err], [Logs.warn], [Logs.info], [Logs.debug] and
      [Logs.msg]. The rule reads these names as the source spells them, so a
      module [Logs] of the project in another file matches too. A file that
      declares a module [Logs] loses this rule. The list is fixed.
    - [int] and [bool] skip a literal in the arguments of [failwith] or
      [invalid_arg], with or without [Stdlib.]. A file that binds one of these
      names loses this rule. The rewriter does not see a binding that an [open]
      or an [include] of another unit brings in. The rule does not cover
      [raise].

    The last two rules are a choice and not an equivalence. A test can read a
    log message or a failure message, and thus kill such a mutant. No test
    should pin the text of a message, as no test should pin a capacity. No
    attribute and no flag gives such a mutant back.

    The arguments of [f] are those of [f x], of [f @@ x], of [x |> f], and of
    [Printf.ksprintf f] and [Format.kasprintf f] applied to a format. [f @@ x]
    and [x |> f] match only when [f] is a name. Thus the message of
    [Logs.err ~src @@ fun m -> ...] keeps its mutants, and that of
    [Logs.err ~src (fun m -> ...)] does not. A statement in the arguments of a
    logging function, of [failwith] or of [invalid_arg] keeps its mutants, with
    the sites inside it. A statement acts on the state of the program. A
    statement is the left operand of a sequence or the expression of
    [let () = e in]. A logging call that is a statement keeps its own [del]
    mutant. These two rules do not see other effects, for example of a function
    that the message calls.

    Two expressions are one expression when their parsetrees are equal without
    their locations. An expression whose value can depend on its location is one
    expression with no other: an expression that holds [assert], [__LOC__],
    [__LINE__], [__POS__], [__LOC_OF__], [__LINE_OF__] or [__POS_OF__] under any
    path, as [Stdlib.__LOC__], a [match], a [function] with cases, a pattern
    that can fail to match, or an extension node. The rewriter does not see the
    location that a backtrace gives for a call.

    An arid site ends the chain of its operator. In [a + b + 0] the outermost
    site is arid, so [a + b] carries its own mutant.

    A [[@mutate off]] on a site that one of the last five rules skips records
    the site as dismissed, as on any other site. The other rules make the
    expression no site, so a [[@mutate off]] there records nothing.

    These rules read the syntax alone, as [ari]'s chains do. *)

(** {2:placement Placement}

    - An expression carries at most one mutant, and [neg] comes last. A
      statement may carry [del] besides its own. A literal, [Some e] and
      [h :: t] carry no other mutant. A condition that is a comparison carries
      [cmp], and one that is a connective carries [con].
    - No guard duplicates another site. A connective with a connective for an
      operand carries no mutant, neither [con] nor [neg], so [a && b && c]
      mutates [b && c] alone. Its operands are boolean contexts all the same.
    - In a file that lost the [con] or the [cmp] family, a condition of that
      family is no longer recognized as one, and carries [neg].
    - In a chain of one arithmetic operator, as [a + b + c], the outermost
      application alone is a site. The rule reads the tree and not the layout,
      so [(a + b) + c] and [f (a + b + c)] carry one mutant too. [a + b - c]
      carries two, because [sub] and [add] are two rewrites, and so does
      [a + b + (c + d)]. An {{!section-arid}arid} site ends the chain.
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
    but for the sites of [del], [int], [bool], [none] and [tail], so a top-level
    [let origin = 1 + 2] carries a site. The [--mutate] loop lists a site that
    ran outside tests alone as evaluated outside tests. *)

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
    payload that names a rewrite, as [[@mutate off gt "reason"]], is refused. *)

(** {1:identification Identification}

    The identifier of a mutant is [<file>:<line>:<col>:<rewrite>], as
    [lib/calc.ml:9:12:add]. The rewriter records the last three and the runtime
    joins the file. [<line>] is the one-based line of the first byte of the
    site, and [<col>] is the zero-based column of that byte, counted in bytes. A
    site in brackets starts at its bracket, so bracketing a site, as
    [[@mutate off]] on an infix expression requires, moves its column by one.
    Two sites may share a line and a column under two rewrites. The site also
    records where it ends, as the line and the column of the byte after its last
    one, which a report prints in the compiler's format and no identifier holds.

    A site is numbered by the order of its allocation, from [0], and the numbers
    are local to the file. That order is the traversal's and not the source's. A
    site comes before the sites inside its operands, and the operands of a
    mutated operator come left to right. The else branch of an [if] comes before
    its then branch, and both before its condition, and the body of a [while]
    comes before its condition.

    The [before] and [after] texts of a site are printed from the parsetree and
    never cut out of the source. The attributes of the site are left out, and
    each run of blanks becomes one space, inside a string literal too, so a text
    is one line. The brackets are those of the printer: [a + b + c] is recorded
    as [(a + b) + c], and its mutant as [(a + b) - c]. The printer gives a list
    as a list literal where it can, so [x :: [y]] is recorded as [[x; y]], and
    its [tail] mutant as [[y]]. The [after] text of a [none] site is [None].

    When the head of a [tail] site written as [h :: t] is a list, as in
    [[x] :: acc] or [(x :: cur) :: acc], it starts at the first byte of the
    site. It would have the identifier of the site, so it has no [tail] site of
    its own. *)

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
      runtime with its eight fields spelled out. A runtime whose record differs
      thus fails to compile against the generated code.
    - [type 'a operands = 'a * 'a], only in a file that holds the guard of an
      ordering rewrite, which annotates its pair of operands with it.
    - [___windtrap_armed___], bound to
      [Windtrap_runtime.Mutate.register ~file ~sites]. The call is made once,
      when the module is initialized, within the preconditions of [register].
      [file] is the input name and [sites] is the table in index order.

    Every generated node has a ghost location, with one exception. The disarmed
    arm of an ordering or [ari] guard is the original application rebuilt over
    the binders, and keeps its location and its attributes. The copy [t'] in the
    guard of [tail] is generated code too, and each of its locations is ghost,
    so that no two nodes share a location.

    In the driver that dune builds for a stanza naming both backends this
    rewriter runs first, so its sites are those stated here and the coverage
    rewriter receives its guards. When the coverage rewriter ran on the file
    first, which is the order of a driver that links this library before
    [ppx_windtrap.coverage], the file holds its visits:
    - [a || b] reaches this rewriter as the [if] of that rewriter. It carries no
      [con] mutant, and an operand that became a condition is mutated as one.
    - the [before] and [after] texts of a site hold the visits inside it, as
      [___windtrap_post_visit___ 0 (f x)] for [f x].
    - the visits, their indices and the booleans of the [if] of [||] are that
      rewriter's generated code, at ghost locations, and carry no site.

    The mutants of such a file are not those of the file under this rewriter
    alone. *)

(** {1:rewriting Rewriting} *)

val transform_impl_file :
  Ppxlib.Expansion_context.Base.t ->
  Ppxlib.Parsetree.structure ->
  Ppxlib.Parsetree.structure
(** [transform_impl_file ctxt ast] is [ast] with a guard at each site and the
    {{!section-generated}generated module} prepended. [ctxt] is read for the
    input name of the file alone.

    The result is [ast] itself in three cases:
    - [ast] has a top-level [[@@@mutate exclude_file]].
    - The input name is [//toplevel//] or [(stdin)], or its base name is
      [.ocamlinit] or [topfind].
    - No site was recorded. A dismissed site is a recorded one, so a file whose
      every site is dismissed is registered, by a module that no guard refers
      to.

    The rewriter reads the [mutate] attributes of the expressions that it
    traverses, of the value bindings at the top level of a structure and of
    module bindings, and those that float in a structure. An attribute anywhere
    else, or inside code that is never mutated or is dismissed, is never
    examined.

    Raises a ppxlib located error, which the driver reports as a compile error
    at the attribute, if an attribute that the rewriter reads:
    - has a payload other than [off], [off] with one string literal, [on] or
      [exclude_file].
    - is [on] or [exclude_file] on an expression or on a binding.
    - is [exclude_file] floating inside a nested structure.
    - is [[@@@mutate off]] inside a region, or [[@@@mutate on]] outside one.

    No other input raises. *)
