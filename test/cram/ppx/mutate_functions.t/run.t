The mutation rewriter over `function` with attributes after parameters,
as pp.exe prints it (see ../mutate.t). From OCaml 5.2, the attributes
are on the cases of the function, and the printer spells them after
`function`. A compiler before 5.2 puts them on the function expression,
so the session runs only from 5.2:

  $ export OCAML_COLOR=never
  $ ../pp.exe -apply windtrap_mutate --impl ./fixture_functions.ml | ../elide.exe
  mutation sites of "./fixture_functions.ml" in Windtrap_mut_________fixture_functions___ml:
    0: 7:37 "drop" "| 0 -> ..." -> "| 0 when false -> ..."
    1: 7:46 "drop" "| _ -> ..." -> "| _ when false -> ..."
    2: 11:16 "sub" "1 + 2" -> "1 - 2"
  let loud =
    ((fun x ->
        function[@@ocaml.warning "-8-57"][@@warning "+8"]
        | 0 when
            if
              Windtrap_mut_________fixture_functions___ml.___windtrap_armed___
                0
            then false
            else true -> x
        | _ when
            if
              Windtrap_mut_________fixture_functions___ml.___windtrap_armed___
                1
            then false
            else true -> 1)
    [@ocaml.warning "-8-57"])
  let quiet ?(d=
    let (__windtrap_mut_2_l, __windtrap_mut_2_r) = (1, 2) in
    if Windtrap_mut_________fixture_functions___ml.___windtrap_armed___ 2
    then __windtrap_mut_2_l - __windtrap_mut_2_r
    else __windtrap_mut_2_l + __windtrap_mut_2_r) x =
    function[@@mutate off "kept"] | 0 -> x + d | _ -> 2
