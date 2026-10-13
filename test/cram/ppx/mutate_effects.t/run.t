The mutation rewriter over the effect cases of OCaml 5.3, as pp.exe
prints them (see ../mutate.t). ppxlib encodes an effect case as an
extension pattern. An effect case matches no value and is no `drop`
site. Thus the one value case of `run` is no site, and `run` gets no
guard. ppxlib 0.37 names the encoding `ppxlib.migration.ppat_effect`,
and ppxlib 0.38 adds the suffix `_503`. The session removes the suffix,
so that it gives the same output with the two versions:

  $ export OCAML_COLOR=never
  $ ../pp.exe -apply windtrap_mutate --impl ./fixture_effects.ml | ../elide.exe |
  > sed 's/ppat_effect_503/ppat_effect/'
  mutation sites of "./fixture_effects.ml" in Windtrap_mut_________fixture_effects___ml:
    0: 12:18 "drop" "| Some v -> ..." -> "| Some v when false -> ..."
    1: 12:32 "drop" "| None -> ..." -> "| None when false -> ..."
    2: 16:16 "drop" "| Not_found -> ..." -> "| Not_found when false -> ..."
  open Effect.Deep
  type _ Effect.t +=  
    | Ask: int Effect.t 
  let run f =
    match f () with
    | v -> v
    | [%ppxlib.migration.ppat_effect ? (Ask, k)] -> continue k 1
  let run_option f =
    ((match f () with
      | Some v when
          if Windtrap_mut_________fixture_effects___ml.___windtrap_armed___ 0
          then false
          else true -> v
      | None when
          if Windtrap_mut_________fixture_effects___ml.___windtrap_armed___ 1
          then false
          else true -> 0
      | [%ppxlib.migration.ppat_effect ? (Ask, k)] -> continue k 1)
    [@ocaml.warning "-8-57"])
  let run_handler f =
    ((try f ()
      with
      | Not_found when
          if Windtrap_mut_________fixture_effects___ml.___windtrap_armed___ 2
          then false
          else true -> 0
      | [%ppxlib.migration.ppat_effect ? (Ask, k)] -> continue k 1)
    [@ocaml.warning "-57"])

The rewriter finds the two names. Thus an effect case with the name of
ppxlib 0.37 is no site with a later ppxlib too:

  $ ../pp.exe -apply windtrap_mutate --impl ./fixture_ppxlib_037.ml | ../elide.exe
  let run f =
    match f () with
    | v -> v
    | [%ppxlib.migration.ppat_effect ? (Ask, k)] -> Effect.Deep.continue k 1
