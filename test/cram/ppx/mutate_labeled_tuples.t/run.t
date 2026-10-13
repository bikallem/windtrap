The mutation rewriter over the labeled tuples of OCaml 5.4, as pp.exe
prints them (see ../mutate.t). ppxlib encodes a labeled tuple as an
extension node, and the printer of ppxlib gives that encoding. The
`before` and `after` texts of a site hold the labeled tuple as the
source spells it:

  $ export OCAML_COLOR=never
  $ ../pp.exe -apply windtrap_mutate --impl ./fixture_labeled_tuples.ml | ../elide.exe
  mutation sites of "./fixture_labeled_tuples.ml" in Windtrap_mut_________fixture_labeled_tuples___ml:
    0: 4:28 "drop" "| (~x:0, ~y) -> ..." -> "| (~x:0, ~y) when false -> ..."
    1: 4:44 "drop" "| (~x, ~y:_) -> ..." -> "| (~x, ~y:_) when false -> ..."
    2: 7:2 "skip" "print_int ((~a, ~b) |> (fun (~a, ~b:_) -> a))" -> "()"
  let x_or_y p =
    ((match p with
      | [%ppxlib.migration.ppat_labeled_tuple_5_4 ?
          (((x, 0), (y, y)), closed_)] when
          if
            Windtrap_mut_________fixture_labeled_tuples___ml.___windtrap_armed___
              0
          then false
          else true -> y
      | [%ppxlib.migration.ppat_labeled_tuple_5_4 ?
          (((x, x), (y, _)), closed_)] when
          if
            Windtrap_mut_________fixture_labeled_tuples___ml.___windtrap_armed___
              1
          then false
          else true -> x)
    [@ocaml.warning "-8-57"])
  let show a b =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_labeled_tuples___ml.___windtrap_armed___
           2)
    then
      (print_int
         (([%ppxlib.migration.pexp_labeled_tuple_5_4
             (((`Some `a), a), ((`Some `b), b))])
            |>
            (fun
               [%ppxlib.migration.ppat_labeled_tuple_5_4 ?
                 (((a, a), (b, _)), closed_)]
               -> a));
       ());
    print_newline ()

A `mutate` attribute on a component of a labeled tuple is inside the
pattern of the case, and the rewriter refuses it, as on a component of
a tuple:

  $ ../pp.exe -apply windtrap_mutate --impl ./reject_off_labeled_tuple.ml
  File "./reject_off_labeled_tuple.ml", line 1, characters 40-59:
  1 | let x_or_y p = match p with ~x:0, ~y:(1 [@mutate off "one"]) -> 1 | ~x, ~y:_ -> x
                                              ^^^^^^^^^^^^^^^^^^^
  Error: mutate off is not allowed inside a pattern. Put it on the whole pattern of the case.
  [1]
