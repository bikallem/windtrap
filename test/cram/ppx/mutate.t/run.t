The mutation rewriter's expansions and refusals, as pp.exe prints them
(see ../coverage.t).

  $ export OCAML_COLOR=never
  $ mut() { ../pp.exe -apply windtrap_mutate "$@"; }

A mutated file opens with a module that registers its sites, shown here
in full. The file is mutated under its own name:

  $ mut --impl ./fixture_input_name.ml
  [@@@ocaml.text "/*"]
  module Windtrap_mut_________fixture_input_name___ml =
    struct
      type site = Windtrap_runtime.Mutate.site =
        {
        line: int ;
        col: int ;
        rewrite: string ;
        before: string ;
        after: string ;
        dismissed: Windtrap_runtime.Mutate.dismissal option }
      type 'a operands = ('a * 'a)
      let ___windtrap_armed___ =
        Windtrap_runtime.Mutate.register ~file:"./fixture_input_name.ml"
          ~sites:[|{
                     line = 5;
                     col = 16;
                     rewrite = "ge";
                     before = "n > 0";
                     after = "n >= 0";
                     dismissed = None
                   }|]
    end
  [@@@ocaml.text "/*"]
  let sign n =
    if
      let (__windtrap_mut_0_l, __windtrap_mut_0_r) =
        ((n, 0) : _ Windtrap_mut_________fixture_input_name___ml.operands) in
      (if Windtrap_mut_________fixture_input_name___ml.___windtrap_armed___ 0
       then Stdlib.not (__windtrap_mut_0_r > __windtrap_mut_0_l)
       else __windtrap_mut_0_l > __windtrap_mut_0_r)
    then 1
    else 0

Every other expansion shows that module condensed by elide.exe to its
file and its sites: the line and column, the rewrite, the text before and
after, and the reason of a dismissed site.

  $ mut --impl ./fixture_all_dismissed.ml | ../elide.exe
  mutation sites of "./fixture_all_dismissed.ml" in Windtrap_mut_________fixture_all_dismissed___ml:
    0: 8:5 "ge" "want > 16" -> "want >= 16", dismissed "both arms yield 16 at the boundary"
  let cap want =
    if ((want > 16)[@mutate off "both arms yield 16 at the boundary"])
    then want
    else 16

  $ mut --impl ./fixture_ari.ml | ../elide.exe
  mutation sites of "./fixture_ari.ml" in Windtrap_mut_________fixture_ari___ml:
    0: 5:14 "sub" "a + b" -> "a - b"
    1: 6:15 "add" "a - b" -> "a + b"
    2: 7:15 "fsub" "a +. b" -> "a -. b"
    3: 8:16 "fadd" "a -. b" -> "a +. b"
    4: 13:13 "sub" "1 + 2" -> "1 - 2"
    5: 17:17 "sub" "a + b" -> "a - b"
  let sum a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_ari___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r
  let diff a b =
    let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (a, b) in
    if Windtrap_mut_________fixture_ari___ml.___windtrap_armed___ 1
    then __windtrap_mut_1_l + __windtrap_mut_1_r
    else __windtrap_mut_1_l - __windtrap_mut_1_r
  let fsum a b =
    let (__windtrap_mut_2_l, __windtrap_mut_2_r) = (a, b) in
    if Windtrap_mut_________fixture_ari___ml.___windtrap_armed___ 2
    then __windtrap_mut_2_l -. __windtrap_mut_2_r
    else __windtrap_mut_2_l +. __windtrap_mut_2_r
  let fdiff a b =
    let (__windtrap_mut_3_l, __windtrap_mut_3_r) = (a, b) in
    if Windtrap_mut_________fixture_ari___ml.___windtrap_armed___ 3
    then __windtrap_mut_3_l +. __windtrap_mut_3_r
    else __windtrap_mut_3_l -. __windtrap_mut_3_r
  let origin =
    let (__windtrap_mut_4_l, __windtrap_mut_4_r) = (1, 2) in
    if Windtrap_mut_________fixture_ari___ml.___windtrap_armed___ 4
    then __windtrap_mut_4_l - __windtrap_mut_4_r
    else __windtrap_mut_4_l + __windtrap_mut_4_r
  let negate x = - x
  let scaled a b =
    (let (__windtrap_mut_5_l, __windtrap_mut_5_r) = (a, b) in
     if Windtrap_mut_________fixture_ari___ml.___windtrap_armed___ 5
     then __windtrap_mut_5_l - __windtrap_mut_5_r
     else __windtrap_mut_5_l + __windtrap_mut_5_r) * 2

  $ mut --impl ./fixture_arm.ml | ../elide.exe
  mutation sites of "./fixture_arm.ml" in Windtrap_mut_________fixture_arm___ml, with type 'a operands:
    0: 8:4 "drop" "| `Add -> ..." -> "| `Add when false -> ..."
    1: 8:12 "sub" "a + b" -> "a - b"
    2: 9:4 "drop" "| `Sub when a > b -> ..." -> "| `Sub when false -> ..."
    3: 9:23 "add" "a - b" -> "a + b"
    4: 9:14 "ge" "a > b" -> "a >= b"
    5: 10:4 "drop" "| `Sub | `Mul -> ..." -> "| `Sub | `Mul when false -> ..."
    6: 12:26 "drop" "| [] -> ..." -> "| [] when false -> ..."
    7: 12:36 "drop" "| _::rest -> ..." -> "| _::rest when false -> ..."
    8: 12:49 "sub" "1 + (length rest)" -> "1 - (length rest)"
    9: 13:29 "drop" "| Not_found -> ..." -> "| Not_found when false -> ..."
    10: 13:46 "drop" "| Exit -> ..." -> "| Exit when false -> ..."
    11: 17:42 "drop" "| exception Not_found -> ..." -> "| exception Not_found when false -> ..."
    12: 22:30 "drop" "| Some y -> ..." -> "| Some y when false -> ..."
    13: 33:26 "drop" "| 0 -> ..." -> "| 0 when false -> ...", dismissed "zero is unused"
    14: 33:64 "sub" "1 + x" -> "1 - x"
    15: 33:72 "drop" "| _ -> ..." -> "| _ when false -> ..."
    16: 43:31 "drop" "| Some y -> ..." -> "| Some y when false -> ..."
    17: 44:45 "drop" "| (exception Not_found : int) -> ..." -> "| (exception Not_found : int) when false -> ..."
    18: 49:15 "drop" "| `A | `B -> ..." -> "| `A | `B when false -> ...", dismissed "the two give one result"
    19: 49:72 "drop" "| `C -> ..." -> "| `C when false -> ..."
    20: 52:15 "sub" "1 + 2" -> "1 - 2"
    21: 52:33 "drop" "| 0 -> ..." -> "| 0 when false -> ..."
    22: 52:42 "drop" "| _ -> ..." -> "| _ when false -> ..."
    23: 55:28 "sub" "a + b" -> "a - b"
    24: 55:39 "drop" "| 0 -> ..." -> "| 0 when false -> ..."
    25: 55:48 "drop" "| _ -> ..." -> "| _ when false -> ..."
    26: 56:24 "add" "a - b" -> "a + b"
    27: 56:37 "drop" "| Not_found -> ..." -> "| Not_found when false -> ..."
    28: 56:54 "drop" "| Exit -> ..." -> "| Exit when false -> ..."
    29: 61:16 "drop" "| Not_found -> ..." -> "| Not_found when false -> ...", dismissed "never raised"
    30: 61:64 "drop" "| Exit -> ..." -> "| Exit when false -> ..."
  let apply op a b =
    ((match op with
      | `Add when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 0
          then false
          else true ->
          let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (a, b) in
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 1
          then __windtrap_mut_1_l - __windtrap_mut_1_r
          else __windtrap_mut_1_l + __windtrap_mut_1_r
      | `Sub when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 2
          then false
          else
            (let (__windtrap_mut_4_l, __windtrap_mut_4_r) =
               ((a, b) : _ Windtrap_mut_________fixture_arm___ml.operands) in
             if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 4
             then Stdlib.not (__windtrap_mut_4_r > __windtrap_mut_4_l)
             else __windtrap_mut_4_l > __windtrap_mut_4_r)
          ->
          let (__windtrap_mut_3_l, __windtrap_mut_3_r) = (a, b) in
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 3
          then __windtrap_mut_3_l + __windtrap_mut_3_r
          else __windtrap_mut_3_l - __windtrap_mut_3_r
      | `Sub | `Mul when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 5
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let rec length =
    ((function
      | [] when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 6
          then false
          else true -> 0
      | _::rest when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 7
          then false
          else true ->
          let (__windtrap_mut_8_l, __windtrap_mut_8_r) = (1, (length rest)) in
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 8
          then __windtrap_mut_8_l - __windtrap_mut_8_r
          else __windtrap_mut_8_l + __windtrap_mut_8_r)
    [@ocaml.warning "-8-57"])
  let handle f =
    ((try f ()
      with
      | Not_found when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 9
          then false
          else true -> 0
      | Exit when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 10
          then false
          else true -> 1)
    [@ocaml.warning "-57"])
  let fallback f =
    ((match f () with
      | v -> v
      | exception Not_found when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 11
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let only x = match x with | Some y -> y
  let mixed f =
    ((match f () with
      | Some y when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 12
          then false
          else true -> y
      | None | exception Not_found -> 0)
    [@ocaml.warning "-8-57"])
  type (_, _) eq =
    | Refl: ('a, 'a) eq 
  let refuted (x : (int, int) eq option) =
    match x with | None -> 0 | Some (Refl) -> 1 | _ -> .
  let kept x =
    ((match x with
      | ((0)[@mutate off "zero is unused"]) when true ->
          let (__windtrap_mut_14_l, __windtrap_mut_14_r) = (1, x) in
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 14
          then __windtrap_mut_14_l - __windtrap_mut_14_r
          else __windtrap_mut_14_l + __windtrap_mut_14_r
      | _ when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 15
          then false
          else true -> x)
    [@ocaml.warning "-8-57"])
  let hidden x = ((match x with | 0 -> 1 | _ -> x + 1)[@mutate off])
  module M = struct exception E  end
  let opened f =
    ((match f () with
      | Some y when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 16
          then false
          else true -> y
      | None | M.(exception E)  -> 0)
    [@ocaml.warning "-8-57"])
  let constrained f =
    ((match f () with
      | y -> y
      | (exception Not_found : int) when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 17
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let either x =
    ((match x with
      | ((`A | `B)[@mutate off "the two give one result"]) when true -> 1
      | `C when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 19
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let pick =
    ((fun ?(d=
        let (__windtrap_mut_20_l, __windtrap_mut_20_r) = (1, 2) in
        if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 20
        then __windtrap_mut_20_l - __windtrap_mut_20_r
        else __windtrap_mut_20_l + __windtrap_mut_20_r) ->
        function
        | 0 when
            if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 21
            then false
            else true -> d
        | _ when
            if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 22
            then false
            else true -> 1)
    [@ocaml.warning "-8-57"])
  let scrutinized a b =
    ((match let (__windtrap_mut_23_l, __windtrap_mut_23_r) = (a, b) in
            if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 23
            then __windtrap_mut_23_l - __windtrap_mut_23_r
            else __windtrap_mut_23_l + __windtrap_mut_23_r
      with
      | 0 when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 24
          then false
          else true -> 1
      | _ when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 25
          then false
          else true -> 2)
    [@ocaml.warning "-8-57"])
  let tried f a b =
    ((try
        f
          (let (__windtrap_mut_26_l, __windtrap_mut_26_r) = (a, b) in
           if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 26
           then __windtrap_mut_26_l + __windtrap_mut_26_r
           else __windtrap_mut_26_l - __windtrap_mut_26_r)
      with
      | Not_found when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 27
          then false
          else true -> 0
      | Exit when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 28
          then false
          else true -> 1)
    [@ocaml.warning "-57"])
  let excused f =
    ((try f ()
      with | ((Not_found)[@mutate off "never raised"]) -> 0
      | Exit when
          if Windtrap_mut_________fixture_arm___ml.___windtrap_armed___ 30
          then false
          else true -> 1)
    [@ocaml.warning "-57"])

  $ mut --impl ./fixture_assert.ml | ../elide.exe
  mutation sites of "./fixture_assert.ml" in Windtrap_mut_________fixture_assert___ml, with type 'a operands:
    0: 7:2 "sub" "a + b" -> "a - b"
    1: 17:21 "or" "(a < b) && (assert false)" -> "(a < b) || (assert false)"
    2: 17:21 "le" "a < b" -> "a <= b"
    3: 25:4 "not" "assert (a < b); a > b" -> "not (assert (a < b); a > b)"
  let checked a b =
    assert (a < b);
    (let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
     if Windtrap_mut_________fixture_assert___ml.___windtrap_armed___ 0
     then __windtrap_mut_0_l - __windtrap_mut_0_r
     else __windtrap_mut_0_l + __windtrap_mut_0_r)
  let conjunction a b = assert (a && b)
  let arithmetic a b = assert ((a + b) > 0)
  let as_condition () = if assert false then 1 else 0
  let as_operand a b =
    let __windtrap_mut_1_p =
      let (__windtrap_mut_2_l, __windtrap_mut_2_r) =
        ((a, b) : _ Windtrap_mut_________fixture_assert___ml.operands) in
      if Windtrap_mut_________fixture_assert___ml.___windtrap_armed___ 2
      then Stdlib.not (__windtrap_mut_2_r < __windtrap_mut_2_l)
      else __windtrap_mut_2_l < __windtrap_mut_2_r in
    if
      Stdlib.(<>) (__windtrap_mut_1_p : Stdlib.Bool.t)
        (Windtrap_mut_________fixture_assert___ml.___windtrap_armed___ 1)
    then assert false
    else __windtrap_mut_1_p
  let sequenced a b =
    if
      let __windtrap_mut_3_p = assert (a < b); a > b in
      (if Windtrap_mut_________fixture_assert___ml.___windtrap_armed___ 3
       then Stdlib.not __windtrap_mut_3_p
       else __windtrap_mut_3_p)
    then 1
    else 0

  $ mut -lit --impl ./fixture_lit.ml | ../elide.exe
  mutation sites of "./fixture_lit.ml" in Windtrap_mut_________fixture_lit___ml:
    0: 6:12 "one" "0" -> "1"
    1: 6:15 "inc" "41" -> "42"
    2: 6:19 "inc" "(-1)" -> "0"
    3: 6:23 "inc" "0x7f" -> "128"
    4: 6:29 "inc" "7l" -> "8l"
    5: 6:33 "inc" "9L" -> "10L"
    6: 6:37 "inc" "3n" -> "4n"
    7: 7:14 "zero" "2.5" -> "0."
    8: 7:19 "one" "0." -> "1."
    9: 7:23 "one" "(-0.0)" -> "1."
    10: 7:29 "zero" "1e3" -> "0."
    11: 11:15 "inc" "4611686018427387903" -> "(-4611686018427387904)"
    12: 19:13 "flip" "true" -> "false"
    13: 19:19 "flip" "false" -> "true"
    14: 20:22 "not" "true" -> "not true"
    15: 21:13 "or" "a && true" -> "a || true"
    16: 21:18 "flip" "true" -> "false"
    17: 27:21 "drop" "| 0 -> ..." -> "| 0 when false -> ..."
    18: 27:35 "drop" "| _ -> ..." -> "| _ when false -> ..."
    19: 28:12 "inc" "2" -> "3"
  let ints =
    ((if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 0
      then 1
      else 0),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 1
       then 42
       else 41),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 2
       then 0
       else (-1)),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 3
       then 128
       else 0x7f),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 4
       then 8l
       else 7l),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 5
       then 10L
       else 9L),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 6
       then 4n
       else 3n))
  let floats =
    ((if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 7
      then 0.
      else 2.5),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 8
       then 1.
       else 0.),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 9
       then 1.
       else (-0.0)),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 10
       then 0.
       else 1e3))
  let greatest =
    if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 11
    then (-4611686018427387904)
    else 4611686018427387903
  let too_big = (4611686018427387905, 2147483649l, 0x1_0000_0000_0000_0000L)
  let flags =
    ((if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 12
      then false
      else true),
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 13
       then true
       else false))
  let forever f =
    while
      let __windtrap_mut_14_p = true in
      if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 14
      then Stdlib.not __windtrap_mut_14_p
      else __windtrap_mut_14_p do f () done
  let both a =
    let __windtrap_mut_15_p = a in
    if
      Stdlib.(<>) (__windtrap_mut_15_p : Stdlib.Bool.t)
        (Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 15)
    then
      (if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 16
       then false
       else true)
    else __windtrap_mut_15_p
  let text = ("text", 'c', 1z)
  let small =
    ((function
      | 0 when
          if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 17
          then false
          else true -> "zero"
      | _ when
          if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 18
          then false
          else true -> "other")
    [@ocaml.warning "-8-57"])
  let noted =
    if Windtrap_mut_________fixture_lit___ml.___windtrap_armed___ 19
    then 3
    else ((2)[@note 5])
  let checked x = assert (x > 0)

  $ mut --impl ./fixture_ret.ml | ../elide.exe
  mutation sites of "./fixture_ret.ml" in Windtrap_mut_________fixture_ret___ml:
    0: 5:13 "none" "Some (x + 1)" -> "None"
    1: 5:18 "sub" "x + 1" -> "x - 1"
    2: 6:16 "tail" "x :: xs" -> "xs"
    3: 7:12 "tail" "[1; 2; 3]" -> "[2; 3]"
    4: 8:15 "tail" "[x; y]" -> "[y]"
    5: 11:18 "tail" "a :: b :: t" -> "b :: t"
    6: 16:22 "tail" "1 :: (Lazy.force stream)" -> "Lazy.force stream"
    7: 17:40 "tail" "n :: (count (n - 1))" -> "count (n - 1)"
    8: 17:51 "add" "n - 1" -> "n + 1"
    9: 17:21 "neq" "n = 0" -> "n <> 0"
  let wrap x =
    if Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 0
    then None
    else
      Some
        ((let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (x, 1) in
          if Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 1
          then __windtrap_mut_1_l - __windtrap_mut_1_r
          else __windtrap_mut_1_l + __windtrap_mut_1_r))
  let push x xs =
    if
      Stdlib.not (Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 2)
    then x :: xs
    else xs
  let three =
    if
      Stdlib.not (Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 3)
    then [1; 2; 3]
    else [2; 3]
  let pair x y =
    if
      Stdlib.not (Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 4)
    then [x; y]
    else [y]
  let chain a b t =
    if
      Stdlib.not (Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 5)
    then a :: b :: t
    else b :: t
  let rec ones = 1 :: ones
  let rec stream =
    lazy
      (if
         Stdlib.not
           (Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 6)
       then 1 :: (Lazy.force stream)
       else Lazy.force stream)
  let rec count n =
    if
      let __windtrap_mut_9_p = n = 0 in
      (if Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 9
       then Stdlib.not __windtrap_mut_9_p
       else __windtrap_mut_9_p)
    then []
    else
      if
        Stdlib.not
          (Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 7)
      then n ::
        (count
           (let (__windtrap_mut_8_l, __windtrap_mut_8_r) = (n, 1) in
            if Windtrap_mut_________fixture_ret___ml.___windtrap_armed___ 8
            then __windtrap_mut_8_l + __windtrap_mut_8_r
            else __windtrap_mut_8_l - __windtrap_mut_8_r))
      else count (n - 1)
  class cycle = let rec ones = 1 :: ones in object method ones = ones end
  let qualified x = Option.Some x
  let empty = (None, [])

  $ mut --impl ./fixture_call.ml | ../elide.exe
  mutation sites of "./fixture_call.ml" in Windtrap_mut_________fixture_call___ml, with type 'a operands:
    0: 6:2 "skip" "incr r" -> "()"
    1: 7:2 "skip" "r := ((!r) + 1)" -> "()"
    2: 7:7 "sub" "(!r) + 1" -> "(!r) - 1"
    3: 11:11 "skip" "incr r" -> "()"
    4: 18:5 "ge" "(!r) > 0" -> "(!r) >= 0"
    5: 22:2 "sub" "x + 1" -> "x - 1"
    6: 28:2 "skip" "a < b" -> "()"
    7: 37:2 "skip" "incr r" -> "()", dismissed "the count is not read"
    8: 43:8 "or" "b && c" -> "b || c"
  let tick r =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_call___ml.___windtrap_armed___ 0)
    then (incr r; ());
    if
      Stdlib.not
        (Windtrap_mut_________fixture_call___ml.___windtrap_armed___ 1)
    then
      (r :=
         ((let (__windtrap_mut_2_l, __windtrap_mut_2_r) = ((!r), 1) in
           if Windtrap_mut_________fixture_call___ml.___windtrap_armed___ 2
           then __windtrap_mut_2_l - __windtrap_mut_2_r
           else __windtrap_mut_2_l + __windtrap_mut_2_r));
       ());
    !r
  let bound r =
    let () =
      if
        Stdlib.not
          (Windtrap_mut_________fixture_call___ml.___windtrap_armed___ 3)
      then incr r in
    !r
  let assign p r =
    p.contents <- 1;
    if
      (let (__windtrap_mut_4_l, __windtrap_mut_4_r) =
         (((!r), 0) : _ Windtrap_mut_________fixture_call___ml.operands) in
       if Windtrap_mut_________fixture_call___ml.___windtrap_armed___ 4
       then Stdlib.not (__windtrap_mut_4_r > __windtrap_mut_4_l)
       else __windtrap_mut_4_l > __windtrap_mut_4_r)
    then incr r;
    r := 2
  let discard x =
    (let (__windtrap_mut_5_l, __windtrap_mut_5_r) = (x, 1) in
     if Windtrap_mut_________fixture_call___ml.___windtrap_armed___ 5
     then __windtrap_mut_5_l - __windtrap_mut_5_r
     else __windtrap_mut_5_l + __windtrap_mut_5_r);
    ()
  let compare_only a b =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_call___ml.___windtrap_armed___ 6)
    then (a < b; ());
    ()
  let () = print_newline ()
  let quiet r = ((incr r)[@mutate off "the count is not read"]); !r
  let chain a b c =
    ((a &&
        ((let __windtrap_mut_8_p = b in
          if
            Stdlib.(<>) (__windtrap_mut_8_p : Stdlib.Bool.t)
              (Windtrap_mut_________fixture_call___ml.___windtrap_armed___ 8)
          then c
          else __windtrap_mut_8_p)))
    [@warning "-10"]);
    ()
  type single =
    | Single 
  let single f x = let Single = f x in x

  $ mut --impl ./fixture_chain.ml | ../elide.exe
  mutation sites of "./fixture_chain.ml" in Windtrap_mut_________fixture_chain___ml, with type 'a operands:
    0: 19:18 "sub" "(a + b) + c" -> "(a + b) - c"
    1: 20:18 "add" "(a - b) - c" -> "(a - b) + c"
    2: 21:19 "fsub" "(a +. b) +. c" -> "(a +. b) -. c"
    3: 22:25 "or" "b && c" -> "b || c"
    4: 31:26 "sub" "(a + b) + c" -> "(a + b) - c"
    5: 32:23 "sub" "(a + b) + c" -> "(a + b) - c"
    6: 33:31 "or" "b && c" -> "b || c"
    7: 39:23 "sub" "(a + b) + (c + d)" -> "(a + b) - (c + d)"
    8: 39:31 "sub" "c + d" -> "c - d"
    9: 43:18 "add" "(a + b) - c" -> "(a + b) + c"
    10: 43:18 "sub" "a + b" -> "a - b"
    11: 48:23 "le" "(a < b) < c" -> "(a < b) <= c"
  let three a b c =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = ((a + b), c) in
    if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r
  let minus a b c =
    let (__windtrap_mut_1_l, __windtrap_mut_1_r) = ((a - b), c) in
    if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 1
    then __windtrap_mut_1_l + __windtrap_mut_1_r
    else __windtrap_mut_1_l - __windtrap_mut_1_r
  let floats a b c =
    let (__windtrap_mut_2_l, __windtrap_mut_2_r) = ((a +. b), c) in
    if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 2
    then __windtrap_mut_2_l -. __windtrap_mut_2_r
    else __windtrap_mut_2_l +. __windtrap_mut_2_r
  let conn a b c =
    if
      a &&
        (let __windtrap_mut_3_p = b in
         (if
            Stdlib.(<>) (__windtrap_mut_3_p : Stdlib.Bool.t)
              (Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 3)
          then c
          else __windtrap_mut_3_p))
    then 1
    else 0
  let parens a b c =
    ignore
      (let (__windtrap_mut_4_l, __windtrap_mut_4_r) = ((a + b), c) in
       if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 4
       then __windtrap_mut_4_l - __windtrap_mut_4_r
       else __windtrap_mut_4_l + __windtrap_mut_4_r)
  let in_arg f a b c =
    f
      (let (__windtrap_mut_5_l, __windtrap_mut_5_r) = ((a + b), c) in
       if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 5
       then __windtrap_mut_5_l - __windtrap_mut_5_r
       else __windtrap_mut_5_l + __windtrap_mut_5_r)
  let conn_arg f a b c =
    f
      (a &&
         (let __windtrap_mut_6_p = b in
          if
            Stdlib.(<>) (__windtrap_mut_6_p : Stdlib.Bool.t)
              (Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 6)
          then c
          else __windtrap_mut_6_p))
  let siblings a b c d =
    let (__windtrap_mut_7_l, __windtrap_mut_7_r) =
      ((a + b),
        (let (__windtrap_mut_8_l, __windtrap_mut_8_r) = (c, d) in
         if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 8
         then __windtrap_mut_8_l - __windtrap_mut_8_r
         else __windtrap_mut_8_l + __windtrap_mut_8_r)) in
    if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 7
    then __windtrap_mut_7_l - __windtrap_mut_7_r
    else __windtrap_mut_7_l + __windtrap_mut_7_r
  let mixed a b c =
    let (__windtrap_mut_9_l, __windtrap_mut_9_r) =
      ((let (__windtrap_mut_10_l, __windtrap_mut_10_r) = (a, b) in
        if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 10
        then __windtrap_mut_10_l - __windtrap_mut_10_r
        else __windtrap_mut_10_l + __windtrap_mut_10_r), c) in
    if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 9
    then __windtrap_mut_9_l + __windtrap_mut_9_r
    else __windtrap_mut_9_l - __windtrap_mut_9_r
  let chained a b c =
    if
      let (__windtrap_mut_11_l, __windtrap_mut_11_r) =
        (((a < b), c) : _ Windtrap_mut_________fixture_chain___ml.operands) in
      (if Windtrap_mut_________fixture_chain___ml.___windtrap_armed___ 11
       then Stdlib.not (__windtrap_mut_11_r < __windtrap_mut_11_l)
       else __windtrap_mut_11_l < __windtrap_mut_11_r)
    then 1
    else 0

  $ mut --impl ./fixture_chain_off.ml | ../elide.exe
  mutation sites of "./fixture_chain_off.ml" in Windtrap_mut_________fixture_chain_off___ml:
    0: 4:19 "sub" "((a + (b - d))[@mutate off]) + c" -> "((a + (b - d))[@mutate off]) - c"
    1: 9:17 "tail" "a :: (((b - 1) :: t)[@mutate off])" -> "(b - 1) :: t"
  let link a b c d =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) =
      (((a + (b - d))[@mutate off]), c) in
    if Windtrap_mut_________fixture_chain_off___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r
  let cons a b t =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_chain_off___ml.___windtrap_armed___ 1)
    then a :: (((b - 1) :: t)[@mutate off])
    else (((b - 1) :: t)[@mutate off])

  $ mut --impl ./fixture_cmp.ml | ../elide.exe
  mutation sites of "./fixture_cmp.ml" in Windtrap_mut_________fixture_cmp___ml, with type 'a operands:
    0: 7:19 "le" "a < b" -> "a <= b"
    1: 8:21 "lt" "a <= b" -> "a < b"
    2: 11:8 "ge" "a > b" -> "a >= b"
    3: 15:32 "drop" "| _ when a >= b -> ..." -> "| _ when false -> ..."
    4: 15:39 "gt" "a >= b" -> "a > b"
    5: 15:53 "drop" "| _ -> ..." -> "| _ when false -> ..."
    6: 16:18 "neq" "a = b" -> "a <> b"
    7: 17:21 "eq" "a <> b" -> "a = b"
    8: 20:21 "or" "(x >= lo) && (x <= hi)" -> "(x >= lo) || (x <= hi)"
    9: 20:21 "gt" "x >= lo" -> "x > lo"
    10: 20:32 "lt" "x <= hi" -> "x < hi"
  let below a b =
    if
      let (__windtrap_mut_0_l, __windtrap_mut_0_r) =
        ((a, b) : _ Windtrap_mut_________fixture_cmp___ml.operands) in
      (if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 0
       then Stdlib.not (__windtrap_mut_0_r < __windtrap_mut_0_l)
       else __windtrap_mut_0_l < __windtrap_mut_0_r)
    then 1
    else 0
  let at_most a b =
    if
      let (__windtrap_mut_1_l, __windtrap_mut_1_r) =
        ((a, b) : _ Windtrap_mut_________fixture_cmp___ml.operands) in
      (if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 1
       then Stdlib.not (__windtrap_mut_1_r <= __windtrap_mut_1_l)
       else __windtrap_mut_1_l <= __windtrap_mut_1_r)
    then 1
    else 0
  let above a b =
    while
      let (__windtrap_mut_2_l, __windtrap_mut_2_r) =
        ((a, b) : _ Windtrap_mut_________fixture_cmp___ml.operands) in
      if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 2
      then Stdlib.not (__windtrap_mut_2_r > __windtrap_mut_2_l)
      else __windtrap_mut_2_l > __windtrap_mut_2_r do () done
  let at_least a b =
    ((match a with
      | _ when
          if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 3
          then false
          else
            (let (__windtrap_mut_4_l, __windtrap_mut_4_r) =
               ((a, b) : _ Windtrap_mut_________fixture_cmp___ml.operands) in
             if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 4
             then Stdlib.not (__windtrap_mut_4_r >= __windtrap_mut_4_l)
             else __windtrap_mut_4_l >= __windtrap_mut_4_r)
          -> 1
      | _ when
          if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 5
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let same a b =
    if
      let __windtrap_mut_6_p = a = b in
      (if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 6
       then Stdlib.not __windtrap_mut_6_p
       else __windtrap_mut_6_p)
    then 1
    else 0
  let differs a b =
    if
      let __windtrap_mut_7_p = a <> b in
      (if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 7
       then Stdlib.not __windtrap_mut_7_p
       else __windtrap_mut_7_p)
    then 1
    else 0
  let window lo hi x =
    let __windtrap_mut_8_p =
      let (__windtrap_mut_9_l, __windtrap_mut_9_r) =
        ((x, lo) : _ Windtrap_mut_________fixture_cmp___ml.operands) in
      if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 9
      then Stdlib.not (__windtrap_mut_9_r >= __windtrap_mut_9_l)
      else __windtrap_mut_9_l >= __windtrap_mut_9_r in
    if
      Stdlib.(<>) (__windtrap_mut_8_p : Stdlib.Bool.t)
        (Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 8)
    then
      let (__windtrap_mut_10_l, __windtrap_mut_10_r) =
        ((x, hi) : _ Windtrap_mut_________fixture_cmp___ml.operands) in
      (if Windtrap_mut_________fixture_cmp___ml.___windtrap_armed___ 10
       then Stdlib.not (__windtrap_mut_10_r <= __windtrap_mut_10_l)
       else __windtrap_mut_10_l <= __windtrap_mut_10_r)
    else __windtrap_mut_8_p
  let ok a b = a < b
  let count a b = List.length (List.filter (fun x -> x < a) b)

  $ mut --impl ./fixture_con.ml | ../elide.exe
  mutation sites of "./fixture_con.ml" in Windtrap_mut_________fixture_con___ml:
    0: 8:15 "or" "a && b" -> "a || b"
    1: 9:17 "and" "a || b" -> "a && b"
    2: 10:22 "or" "ready && x" -> "ready || x"
    3: 11:28 "drop" "| [] -> ..." -> "| [] when false -> ..."
    4: 11:42 "drop" "| x::rest -> ..." -> "| x::rest when false -> ..."
    5: 11:55 "and" "(p x) || (search p rest)" -> "(p x) && (search p rest)"
  let both a b =
    let __windtrap_mut_0_p = a in
    if
      Stdlib.(<>) (__windtrap_mut_0_p : Stdlib.Bool.t)
        (Windtrap_mut_________fixture_con___ml.___windtrap_armed___ 0)
    then b
    else __windtrap_mut_0_p
  let either a b =
    let __windtrap_mut_1_p = a in
    if
      Stdlib.(=) (__windtrap_mut_1_p : Stdlib.Bool.t)
        (Windtrap_mut_________fixture_con___ml.___windtrap_armed___ 1)
    then b
    else __windtrap_mut_1_p
  let gate ready x =
    if
      let __windtrap_mut_2_p = ready in
      (if
         Stdlib.(<>) (__windtrap_mut_2_p : Stdlib.Bool.t)
           (Windtrap_mut_________fixture_con___ml.___windtrap_armed___ 2)
       then x
       else __windtrap_mut_2_p)
    then 1
    else 0
  let rec search =
    ((fun p ->
        function
        | [] when
            if Windtrap_mut_________fixture_con___ml.___windtrap_armed___ 3
            then false
            else true -> false
        | x::rest when
            if Windtrap_mut_________fixture_con___ml.___windtrap_armed___ 4
            then false
            else true ->
            let __windtrap_mut_5_p = p x in
            if
              Stdlib.(=) (__windtrap_mut_5_p : Stdlib.Bool.t)
                (Windtrap_mut_________fixture_con___ml.___windtrap_armed___ 5)
            then search p rest
            else __windtrap_mut_5_p)
    [@ocaml.warning "-8-57"])

  $ mut --impl ./fixture_contexts.ml | ../elide.exe
  mutation sites of "./fixture_contexts.ml" in Windtrap_mut_________fixture_contexts___ml, with type 'a operands:
    0: 5:19 "and" "(a < b) || c" -> "(a < b) && c"
    1: 5:19 "le" "a < b" -> "a <= b"
    2: 12:4 "not" "let x = a in x < b" -> "not (let x = a in x < b)"
    3: 17:32 "not" "(a < b : bool)" -> "not (a < b : bool)"
    4: 18:25 "not" "not (a < b)" -> "not (not (a < b))"
    5: 23:34 "and" "c || d" -> "c && d"
    6: 23:25 "le" "a < b" -> "a <= b"
    7: 29:27 "not" "a & b" -> "not (a & b)"
    8: 34:33 "not" "Float.(<) a b" -> "not (Float.(<) a b)"
    9: 40:16 "sub" "a + b" -> "a - b"
  let either a b c =
    let __windtrap_mut_0_p =
      let (__windtrap_mut_1_l, __windtrap_mut_1_r) =
        ((a, b) : _ Windtrap_mut_________fixture_contexts___ml.operands) in
      if Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___ 1
      then Stdlib.not (__windtrap_mut_1_r < __windtrap_mut_1_l)
      else __windtrap_mut_1_l < __windtrap_mut_1_r in
    if
      Stdlib.(=) (__windtrap_mut_0_p : Stdlib.Bool.t)
        (Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___ 0)
    then c
    else __windtrap_mut_0_p
  let through_let a b =
    if
      let __windtrap_mut_2_p = let x = a in x < b in
      (if Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___ 2
       then Stdlib.not __windtrap_mut_2_p
       else __windtrap_mut_2_p)
    then 1
    else 0
  let through_constraint a b =
    if
      let __windtrap_mut_3_p = (a < b : bool) in
      (if Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___ 3
       then Stdlib.not __windtrap_mut_3_p
       else __windtrap_mut_3_p)
    then 1
    else 0
  let through_not a b =
    if
      let __windtrap_mut_4_p = not (a < b) in
      (if Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___ 4
       then Stdlib.not __windtrap_mut_4_p
       else __windtrap_mut_4_p)
    then 1
    else 0
  let skipped a b c d =
    if
      (let (__windtrap_mut_6_l, __windtrap_mut_6_r) =
         ((a, b) : _ Windtrap_mut_________fixture_contexts___ml.operands) in
       if Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___ 6
       then Stdlib.not (__windtrap_mut_6_r < __windtrap_mut_6_l)
       else __windtrap_mut_6_l < __windtrap_mut_6_r) &&
        (let __windtrap_mut_5_p = c in
         (if
            Stdlib.(=) (__windtrap_mut_5_p : Stdlib.Bool.t)
              (Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___
                 5)
          then d
          else __windtrap_mut_5_p))
    then 1
    else 0
  let old_and a b = a & b
  let old_or a b = a or b
  let old_condition a b =
    if
      let __windtrap_mut_7_p = a & b in
      (if Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___ 7
       then Stdlib.not __windtrap_mut_7_p
       else __windtrap_mut_7_p)
    then 1
    else 0
  let qualified a b = Stdlib.(+) a b
  let qualified_condition a b =
    if
      let __windtrap_mut_8_p = Float.(<) a b in
      (if Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___ 8
       then Stdlib.not __windtrap_mut_8_p
       else __windtrap_mut_8_p)
    then 1
    else 0
  let partial = (+) 1
  let labelled a b = (+) ~a b
  let total a b =
    let (__windtrap_mut_9_l, __windtrap_mut_9_r) = (a, b) in
    if Windtrap_mut_________fixture_contexts___ml.___windtrap_armed___ 9
    then __windtrap_mut_9_l - __windtrap_mut_9_r
    else __windtrap_mut_9_l + __windtrap_mut_9_r

  $ mut --impl ./fixture_empty.ml | ../elide.exe
  type t =
    | A 
    | B 
  let x = 1
  let s = "hello"
  let pair a b = (a, b)

The filter records each site that the syntax shows equivalent to the
original, or that changes a logging call or a failure message alone, as
filtered, with its reason, and gives it no guard:

  $ mut --impl ./fixture_equivalent_ari.ml | ../elide.exe
  mutation sites of "./fixture_equivalent_ari.ml" in Windtrap_mut_________fixture_equivalent_ari___ml:
    0: 7:13 "sub" "x + 0" -> "x - 0", filtered "zero operand"
    1: 8:14 "add" "x - 0" -> "x + 0", filtered "zero operand"
    2: 9:12 "sub" "x + 0x0" -> "x - 0x0", filtered "zero operand"
    3: 10:13 "sub" "0 + x" -> "0 - x"
    4: 11:14 "fsub" "x +. 0." -> "x -. 0."
    5: 12:16 "sub" "a + b" -> "a - b"
    6: 13:17 "sub" "x + 0l" -> "x - 0l"
  let plus x = x + 0
  let minus x = x - 0
  let hex x = x + 0x0
  let left x =
    let (__windtrap_mut_3_l, __windtrap_mut_3_r) = (0, x) in
    if Windtrap_mut_________fixture_equivalent_ari___ml.___windtrap_armed___ 3
    then __windtrap_mut_3_l - __windtrap_mut_3_r
    else __windtrap_mut_3_l + __windtrap_mut_3_r
  let fplus x =
    let (__windtrap_mut_4_l, __windtrap_mut_4_r) = (x, 0.) in
    if Windtrap_mut_________fixture_equivalent_ari___ml.___windtrap_armed___ 4
    then __windtrap_mut_4_l -. __windtrap_mut_4_r
    else __windtrap_mut_4_l +. __windtrap_mut_4_r
  let chain a b =
    (let (__windtrap_mut_5_l, __windtrap_mut_5_r) = (a, b) in
     if Windtrap_mut_________fixture_equivalent_ari___ml.___windtrap_armed___ 5
     then __windtrap_mut_5_l - __windtrap_mut_5_r
     else __windtrap_mut_5_l + __windtrap_mut_5_r) + 0
  let suffixed x =
    let (__windtrap_mut_6_l, __windtrap_mut_6_r) = (x, 0l) in
    if Windtrap_mut_________fixture_equivalent_ari___ml.___windtrap_armed___ 6
    then __windtrap_mut_6_l - __windtrap_mut_6_r
    else __windtrap_mut_6_l + __windtrap_mut_6_r

  $ mut --impl ./fixture_equivalent_con.ml | ../elide.exe
  mutation sites of "./fixture_equivalent_con.ml" in Windtrap_mut_________fixture_equivalent_con___ml:
    0: 7:13 "or" "a && a" -> "a || a", filtered "same operands"
    1: 8:15 "and" "a || a" -> "a && a", filtered "same operands"
    2: 9:14 "or" "r.ok && r.ok" -> "r.ok || r.ok", filtered "same operands"
    3: 10:16 "or" "(f x) && (f x)" -> "(f x) || (f x)"
    4: 11:16 "or" "a && b" -> "a || b"
  type r = {
    mutable ok: bool }
  let both a = a && a
  let either a = a || a
  let field r = r.ok && r.ok
  let calls f x =
    let __windtrap_mut_3_p = f x in
    if
      Stdlib.(<>) (__windtrap_mut_3_p : Stdlib.Bool.t)
        (Windtrap_mut_________fixture_equivalent_con___ml.___windtrap_armed___
           3)
    then f x
    else __windtrap_mut_3_p
  let other a b =
    let __windtrap_mut_4_p = a in
    if
      Stdlib.(<>) (__windtrap_mut_4_p : Stdlib.Bool.t)
        (Windtrap_mut_________fixture_equivalent_con___ml.___windtrap_armed___
           4)
    then b
    else __windtrap_mut_4_p

  $ mut --impl ./fixture_equivalent_neg.ml | ../elide.exe
  mutation sites of "./fixture_equivalent_neg.ml" in Windtrap_mut_________fixture_equivalent_neg___ml:
    0: 8:36 "sub" "x + 1" -> "x - 1"
    1: 8:25 "sub" "x + 1" -> "x - 1"
    2: 8:18 "not" "c" -> "not c", filtered "same branches"
    3: 9:21 "le" "a < b" -> "a <= b", filtered "same branches"
    4: 10:19 "not" "f (x + 1)" -> "not (f (x + 1))", filtered "same branches"
    5: 10:21 "sub" "x + 1" -> "x - 1"
    6: 11:20 "or" "a && b" -> "a || b"
    7: 12:17 "not" "c" -> "not c"
    8: 13:16 "not" "c" -> "not c"
    9: 14:18 "not" "c" -> "not c"
    10: 16:5 "not" "c" -> "not c"
    11: 17:21 "neq" "a = b" -> "a <> b", filtered "same branches"
  let flag c x =
    if c
    then
      let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (x, 1) in
      (if
         Windtrap_mut_________fixture_equivalent_neg___ml.___windtrap_armed___
           1
       then __windtrap_mut_1_l - __windtrap_mut_1_r
       else __windtrap_mut_1_l + __windtrap_mut_1_r)
    else
      (let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (x, 1) in
       if
         Windtrap_mut_________fixture_equivalent_neg___ml.___windtrap_armed___
           0
       then __windtrap_mut_0_l - __windtrap_mut_0_r
       else __windtrap_mut_0_l + __windtrap_mut_0_r)
  let order a b x = if a < b then x else x
  let inner f x =
    if
      f
        (let (__windtrap_mut_5_l, __windtrap_mut_5_r) = (x, 1) in
         if
           Windtrap_mut_________fixture_equivalent_neg___ml.___windtrap_armed___
             5
         then __windtrap_mut_5_l - __windtrap_mut_5_r
         else __windtrap_mut_5_l + __windtrap_mut_5_r)
    then 0
    else 0
  let both a b x =
    if
      let __windtrap_mut_6_p = a in
      (if
         Stdlib.(<>) (__windtrap_mut_6_p : Stdlib.Bool.t)
           (Windtrap_mut_________fixture_equivalent_neg___ml.___windtrap_armed___
              6)
       then b
       else __windtrap_mut_6_p)
    then x
    else x
  let other c =
    if
      let __windtrap_mut_7_p = c in
      (if
         Windtrap_mut_________fixture_equivalent_neg___ml.___windtrap_armed___
           7
       then Stdlib.not __windtrap_mut_7_p
       else __windtrap_mut_7_p)
    then 1
    else 2
  let line c =
    if
      let __windtrap_mut_8_p = c in
      (if
         Windtrap_mut_________fixture_equivalent_neg___ml.___windtrap_armed___
           8
       then Stdlib.not __windtrap_mut_8_p
       else __windtrap_mut_8_p)
    then __LINE__
    else __LINE__
  let blanks c =
    if
      let __windtrap_mut_9_p = c in
      (if
         Windtrap_mut_________fixture_equivalent_neg___ml.___windtrap_armed___
           9
       then Stdlib.not __windtrap_mut_9_p
       else __windtrap_mut_9_p)
    then "a  b"
    else "a b"
  let partial c x =
    if
      let __windtrap_mut_10_p = c in
      (if
         Windtrap_mut_________fixture_equivalent_neg___ml.___windtrap_armed___
           10
       then Stdlib.not __windtrap_mut_10_p
       else __windtrap_mut_10_p)
    then match x with | Some y -> y
    else (match x with | Some y -> y)
  let equal a b x = if a = b then x else x

  $ mut --impl ./fixture_equivalent_arm.ml | ../elide.exe
  mutation sites of "./fixture_equivalent_arm.ml" in Windtrap_mut_________fixture_equivalent_arm___ml:
    0: 9:20 "drop" "| `A -> ..." -> "| `A when false -> ...", filtered "same body as the next case"
    1: 9:30 "drop" "| _ -> ..." -> "| _ when false -> ..."
    2: 10:21 "drop" "| Some _x -> ..." -> "| Some _x when false -> ..."
    3: 10:36 "drop" "| _ -> ..." -> "| _ when false -> ..."
    4: 11:25 "drop" "| `A when p -> ..." -> "| `A when false -> ..."
    5: 11:33 "not" "p" -> "not p"
    6: 11:42 "drop" "| _ -> ..." -> "| _ when false -> ..."
    7: 12:21 "drop" "| `A -> ..." -> "| `A when false -> ..."
    8: 12:31 "drop" "| x -> ..." -> "| x when false -> ..."
    9: 12:36 "skip" "ignore x" -> "()"
    10: 13:22 "drop" "| `A -> ..." -> "| `A when false -> ...", filtered "same body as the next case"
    11: 13:35 "drop" "| _ -> ..." -> "| _ when false -> ..."
    12: 14:30 "drop" "| Not_found -> ..." -> "| Not_found when false -> ...", filtered "same body as the next case"
    13: 14:47 "drop" "| _ -> ..." -> "| _ when false -> ..."
    14: 16:27 "drop" "| exception Not_found -> ..." -> "| exception Not_found when false -> ...", filtered "same body as the next case"
    15: 16:54 "drop" "| exception _ -> ..." -> "| exception _ when false -> ..."
    16: 17:22 "drop" "| (lazy 0) -> ..." -> "| (lazy 0) when false -> ..."
    17: 17:36 "drop" "| _ -> ..." -> "| _ when false -> ..."
    18: 18:30 "drop" "| `A -> ..." -> "| `A when false -> ..."
    19: 18:40 "drop" "| _ when p -> ..." -> "| _ when false -> ..."
    20: 18:47 "not" "p" -> "not p"
    21: 19:30 "drop" "| exception Not_found -> ..." -> "| exception Not_found when false -> ..."
    22: 20:28 "drop" "| 1 -> ..." -> "| 1 when false -> ..."
    23: 20:37 "drop" "| 2 -> ..." -> "| 2 when false -> ..."
    24: 20:46 "drop" "| exception _ -> ..." -> "| exception _ when false -> ..."
  let kind =
    ((function
      | `A when true -> 0
      | _ when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              1
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let bound =
    ((function
      | Some _x when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              2
          then false
          else true -> 0
      | _ when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              3
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let guarded =
    ((fun p ->
        function
        | `A when
            if
              Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
                4
            then false
            else
              (let __windtrap_mut_5_p = p in
               if
                 Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
                   5
               then Stdlib.not __windtrap_mut_5_p
               else __windtrap_mut_5_p)
            -> 0
        | _ when
            if
              Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
                6
            then false
            else true -> 0)
    [@ocaml.warning "-8-57"])
  let named =
    ((function
      | `A when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              7
          then false
          else true -> 0
      | x when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              8
          then false
          else true ->
          (if
             Stdlib.not
               (Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
                  9)
           then (ignore x; ());
           0))
    [@ocaml.warning "-8-57"])
  let call =
    ((fun f ->
        function
        | `A when true -> f ()
        | _ when
            if
              Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
                11
            then false
            else true -> f ())
    [@ocaml.warning "-8-57"])
  let handler f =
    ((try f ()
      with | Not_found -> 0
      | _ when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              13
          then false
          else true -> 0)
    [@ocaml.warning "-57"])
  let raised f =
    ((match f () with
      | v -> v
      | exception Not_found -> 0
      | exception _ when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              15
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let forced =
    ((function
      | (lazy 0) when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              16
          then false
          else true -> 1
      | _ when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              17
          then false
          else true -> 1)
    [@ocaml.warning "-8-57"])
  let next_guarded =
    ((fun p ->
        function
        | `A when
            if
              Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
                18
            then false
            else true -> 0
        | _ when
            if
              Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
                19
            then false
            else
              (let __windtrap_mut_20_p = p in
               if
                 Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
                   20
               then Stdlib.not __windtrap_mut_20_p
               else __windtrap_mut_20_p)
            -> 0)
    [@ocaml.warning "-8-57"])
  let value f =
    ((match f () with
      | exception Not_found when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              21
          then false
          else true -> 0
      | _ -> 0)
    [@ocaml.warning "-8-57"])
  let exn f =
    ((match f () with
      | 1 when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              22
          then false
          else true -> 0
      | 2 when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              23
          then false
          else true -> 0
      | exception _ when
          if
            Windtrap_mut_________fixture_equivalent_arm___ml.___windtrap_armed___
              24
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])

Each filter reads these forms, and a form that it does not read keeps its
mutant:

  $ mut --impl ./fixture_equivalent_forms.ml | ../elide.exe | head -25
  mutation sites of "./fixture_equivalent_forms.ml" in Windtrap_mut_________fixture_equivalent_forms___ml, with type 'a operands:
    0: 8:21 "or" "true && true" -> "true || true", filtered "same operands"
    1: 9:20 "and" "(a : bool) || (a : bool)" -> "(a : bool) && (a : bool)", filtered "same operands"
    2: 10:15 "not" "c" -> "not c"
    3: 11:20 "not" "c" -> "not c"
    4: 12:21 "not" "c" -> "not c"
    5: 13:20 "not" "c" -> "not c"
    6: 16:68 "ge" "y > 0" -> "y >= 0"
    7: 16:32 "ge" "y > 0" -> "y >= 0"
    8: 16:5 "not" "c" -> "not c"
    9: 19:60 "ge" "y > 0" -> "y >= 0"
    10: 19:28 "ge" "y > 0" -> "y >= 0"
    11: 19:5 "not" "c" -> "not c"
    12: 21:63 "sub" "a + b" -> "a - b"
    13: 21:38 "sub" "a + b" -> "a - b"
    14: 21:17 "not" "c" -> "not c", filtered "same branches"
    15: 22:17 "not" "c" -> "not c", filtered "same branches"
    16: 23:17 "not" "c" -> "not c", filtered "same branches"
    17: 24:16 "not" "c" -> "not c", filtered "same branches"
    18: 25:19 "drop" "| `A -> ..." -> "| `A when false -> ...", filtered "same body as the next case"
    19: 25:29 "drop" "| (_ : [ `A | `B ]) -> ..." -> "| (_ : [ `A | `B ]) when false -> ..."
    20: 26:21 "drop" "| `A as _v -> ..." -> "| `A as _v when false -> ..."
    21: 26:37 "drop" "| _ -> ..." -> "| _ when false -> ..."
    22: 27:22 "drop" "| ((module M) : (module S)) -> ..." -> "| ((module M) : (module S)) when false -> ..."
    23: 27:44 "drop" "| _ -> ..." -> "| _ when false -> ..."

Code that gives its location keeps the mutants of its two copies:

  $ mut --impl ./fixture_equivalent_located.ml | ../elide.exe | head -14
  mutation sites of "./fixture_equivalent_located.ml" in Windtrap_mut_________fixture_equivalent_located___ml, with type 'a operands:
    0: 9:20 "ge" "x > 0" -> "x >= 0"
    1: 10:15 "not" "c" -> "not c"
    2: 11:21 "not" "c" -> "not c"
    3: 12:15 "not" "c" -> "not c"
    4: 13:16 "not" "c" -> "not c"
    5: 14:20 "drop" "| 0 -> ..." -> "| 0 when false -> ..."
    6: 14:42 "drop" "| _ -> ..." -> "| _ when false -> ..."
    7: 15:21 "not" "c" -> "not c"
    8: 18:21 "not" "c" -> "not c"
    9: 19:23 "not" "c" -> "not c"
    10: 20:18 "not" "c" -> "not c"
    11: 21:19 "not" "c" -> "not c"
    12: 22:26 "not" "c" -> "not c"

  $ mut --impl ./fixture_equivalent_log.ml | ../elide.exe
  mutation sites of "./fixture_equivalent_log.ml" in Windtrap_mut_________fixture_equivalent_log___ml:
    0: 8:45 "sub" "x + 1" -> "x - 1", filtered "logging call"
    1: 8:70 "none" "Some x" -> "None", filtered "logging call"
    2: 9:42 "add" "x - 1" -> "x + 1", filtered "logging call"
    3: 10:33 "sub" "x + 1" -> "x - 1"
    4: 13:2 "skip" "Log.debug (fun m -> m \"%d\" (x + 1))" -> "()"
    5: 13:29 "sub" "x + 1" -> "x - 1"
    6: 16:38 "sub" "x + 1" -> "x - 1", filtered "logging call"
    7: 17:38 "sub" "x + 1" -> "x - 1", filtered "logging call"
    8: 18:40 "sub" "x + 1" -> "x - 1", filtered "logging call"
    9: 19:48 "sub" "x + 1" -> "x - 1", filtered "logging call"
    10: 22:2 "skip" "Logs.debug (fun m -> y := ((!y) + 1); (let () = incr y in m \"%d\" (!y)))" -> "()"
    11: 23:6 "skip" "y := ((!y) + 1)" -> "()"
    12: 23:11 "sub" "(!y) + 1" -> "(!y) - 1"
    13: 24:15 "skip" "incr y" -> "()"
    14: 26:2 "sub" "(!y) + x" -> "(!y) - x"
  let debug x =
    Logs.debug
      (fun m -> m "%d %a" (x + 1) (let open Fmt in option int) (Some x))
  let info x = Logs.info @@ (fun m -> m "%d" (x - 1))
  let print x =
    Printf.printf "%d"
      (let (__windtrap_mut_3_l, __windtrap_mut_3_r) = (x, 1) in
       if
         Windtrap_mut_________fixture_equivalent_log___ml.___windtrap_armed___
           3
       then __windtrap_mut_3_l - __windtrap_mut_3_r
       else __windtrap_mut_3_l + __windtrap_mut_3_r)
  let local x =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_equivalent_log___ml.___windtrap_armed___
           4)
    then
      (Log.debug
         (fun m ->
            m "%d"
              (let (__windtrap_mut_5_l, __windtrap_mut_5_r) = (x, 1) in
               if
                 Windtrap_mut_________fixture_equivalent_log___ml.___windtrap_armed___
                   5
               then __windtrap_mut_5_l - __windtrap_mut_5_r
               else __windtrap_mut_5_l + __windtrap_mut_5_r));
       ());
    x
  let app x = Logs.app (fun m -> m "%d" (x + 1))
  let err x = Logs.err (fun m -> m "%d" (x + 1))
  let warn x = Logs.warn (fun m -> m "%d" (x + 1))
  let msg x = Logs.msg Logs.Info (fun m -> m "%d" (x + 1))
  let counted y x =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_equivalent_log___ml.___windtrap_armed___
           10)
    then
      (Logs.debug
         (fun m ->
            if
              Stdlib.not
                (Windtrap_mut_________fixture_equivalent_log___ml.___windtrap_armed___
                   11)
            then
              (y :=
                 ((let (__windtrap_mut_12_l, __windtrap_mut_12_r) = ((!y), 1) in
                   if
                     Windtrap_mut_________fixture_equivalent_log___ml.___windtrap_armed___
                       12
                   then __windtrap_mut_12_l - __windtrap_mut_12_r
                   else __windtrap_mut_12_l + __windtrap_mut_12_r));
               ());
            (let () =
               if
                 Stdlib.not
                   (Windtrap_mut_________fixture_equivalent_log___ml.___windtrap_armed___
                      13)
               then incr y in
             m "%d" (!y)));
       ());
    (let (__windtrap_mut_14_l, __windtrap_mut_14_r) = ((!y), x) in
     if
       Windtrap_mut_________fixture_equivalent_log___ml.___windtrap_armed___ 14
     then __windtrap_mut_14_l - __windtrap_mut_14_r
     else __windtrap_mut_14_l + __windtrap_mut_14_r)

  $ mut -log-function Log.debug --impl ./fixture_equivalent_log.ml | ../elide.exe | head -8
  mutation sites of "./fixture_equivalent_log.ml" in Windtrap_mut_________fixture_equivalent_log___ml:
    0: 8:45 "sub" "x + 1" -> "x - 1", filtered "logging call"
    1: 8:70 "none" "Some x" -> "None", filtered "logging call"
    2: 9:42 "add" "x - 1" -> "x + 1", filtered "logging call"
    3: 10:33 "sub" "x + 1" -> "x - 1"
    4: 13:2 "skip" "Log.debug (fun m -> m \"%d\" (x + 1))" -> "()"
    5: 13:29 "sub" "x + 1" -> "x - 1", filtered "logging call"
    6: 16:38 "sub" "x + 1" -> "x - 1", filtered "logging call"

  $ mut -lit --impl ./fixture_equivalent_lit.ml | ../elide.exe
  mutation sites of "./fixture_equivalent_lit.ml" in Windtrap_mut_________fixture_equivalent_lit___ml:
    0: 8:54 "sub" "n + 1" -> "n - 1"
    1: 8:59 "inc" "1" -> "2", filtered "failure message"
    2: 8:62 "inc" "10" -> "11", filtered "failure message"
    3: 9:51 "inc" "3" -> "4", filtered "failure message"
    4: 10:54 "inc" "4" -> "5", filtered "failure message"
    5: 11:29 "inc" "5" -> "6", filtered "failure message"
    6: 12:55 "inc" "6" -> "7"
    7: 13:56 "inc" "8" -> "9", filtered "failure message"
    8: 14:50 "inc" "9" -> "10", filtered "failure message"
    9: 15:38 "one" "0" -> "1", filtered "failure message"
    10: 16:44 "zero" "2.5" -> "0.", filtered "failure message"
    11: 17:46 "one" "0." -> "1.", filtered "failure message"
    12: 18:39 "flip" "true" -> "false", filtered "failure message"
    13: 19:25 "skip" "r := 5" -> "()"
    14: 19:30 "inc" "5" -> "6"
    15: 20:36 "skip" "r := 7" -> "()"
    16: 20:41 "inc" "7" -> "8"
  let fail n =
    failwith
      (Printf.sprintf "item %d of %d"
         (let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (n, 1) in
          if
            Windtrap_mut_________fixture_equivalent_lit___ml.___windtrap_armed___
              0
          then __windtrap_mut_0_l - __windtrap_mut_0_r
          else __windtrap_mut_0_l + __windtrap_mut_0_r) 10)
  let invalid () = Stdlib.invalid_arg (string_of_int 3)
  let formatted () = Printf.ksprintf failwith "code %d" 4
  let piped () = (string_of_int 5) |> failwith
  let raised () =
    raise
      (Invalid_argument
         (string_of_int
            (if
               Windtrap_mut_________fixture_equivalent_lit___ml.___windtrap_armed___
                 6
             then 7
             else 6)))
  let kformatted () = Format.kasprintf failwith "code %d" 8
  let qualified () = Stdlib.failwith (string_of_int 9)
  let zero () = failwith (string_of_int 0)
  let float () = invalid_arg (string_of_float 2.5)
  let float_zero () = failwith (string_of_float 0.)
  let flag () = failwith (string_of_bool true)
  let stated r =
    failwith
      (if
         Stdlib.not
           (Windtrap_mut_________fixture_equivalent_lit___ml.___windtrap_armed___
              13)
       then
         (r :=
            (if
               Windtrap_mut_________fixture_equivalent_lit___ml.___windtrap_armed___
                 14
             then 6
             else 5);
          ());
       "boom")
  let bound r =
    invalid_arg
      (let () =
         if
           Stdlib.not
             (Windtrap_mut_________fixture_equivalent_lit___ml.___windtrap_armed___
                15)
         then
           r :=
             ((if
                 Windtrap_mut_________fixture_equivalent_lit___ml.___windtrap_armed___
                   16
               then 8
               else 7)) in
       "boom")

  $ mut -lit --impl ./fixture_equivalent_lit_bound.ml | ../elide.exe | head -4
  mutation sites of "./fixture_equivalent_lit_bound.ml" in Windtrap_mut_________fixture_equivalent_lit_bound___ml:
    0: 3:17 "sub" "n + 1" -> "n - 1"
    1: 3:21 "inc" "1" -> "2"
    2: 4:23 "inc" "7" -> "8"

  $ mut -lit --impl ./fixture_equivalent_lit_bound_invalid.ml | ../elide.exe | head -4
  mutation sites of "./fixture_equivalent_lit_bound_invalid.ml" in Windtrap_mut_________fixture_equivalent_lit_bound_invalid___ml:
    0: 3:20 "sub" "n + 1" -> "n - 1"
    1: 3:24 "inc" "1" -> "2"
    2: 4:26 "inc" "7" -> "8"

A [@mutate off] on a site that a filter would take dismisses the site,
and keeps its reason:

  $ mut -lit --impl ./fixture_equivalent_off.ml | ../elide.exe | grep -E '^ +[0-9]+: '
    0: 4:13 "sub" "x + 0" -> "x - 0", dismissed "zero is kept"
    1: 5:13 "or" "a && a" -> "a || a", dismissed "one operand"
    2: 6:18 "not" "c" -> "not c", dismissed "one branch"
    3: 7:22 "drop" "| `A -> ..." -> "| `A when false -> ...", dismissed "one case"
    4: 7:59 "drop" "| _ -> ..." -> "| _ when false -> ..."
    5: 8:42 "sub" "x + 1" -> "x - 1", dismissed "a log"
    6: 9:38 "inc" "3" -> "4", dismissed "a message"

The backend flag -no-filter tests every mutant, which no filter then
records:

  $ mut -no-filter --impl ./fixture_equivalent_ari.ml | ../elide.exe | head -9
  mutation sites of "./fixture_equivalent_ari.ml" in Windtrap_mut_________fixture_equivalent_ari___ml:
    0: 7:13 "sub" "x + 0" -> "x - 0"
    1: 8:14 "add" "x - 0" -> "x + 0"
    2: 9:12 "sub" "x + 0x0" -> "x - 0x0"
    3: 10:13 "sub" "0 + x" -> "0 - x"
    4: 11:14 "fsub" "x +. 0." -> "x -. 0."
    5: 12:16 "sub" "(a + b) + 0" -> "(a + b) - 0"
    6: 13:17 "sub" "x + 0l" -> "x - 0l"
  let plus x =
  $ sites() { mut -no-filter "$@" | ../elide.exe | grep -E '^ +[0-9]+: '; }
  $ sites --impl ./fixture_equivalent_con.ml
    0: 7:13 "or" "a && a" -> "a || a"
    1: 8:15 "and" "a || a" -> "a && a"
    2: 9:14 "or" "r.ok && r.ok" -> "r.ok || r.ok"
    3: 10:16 "or" "(f x) && (f x)" -> "(f x) || (f x)"
    4: 11:16 "or" "a && b" -> "a || b"
  $ sites --impl ./fixture_equivalent_neg.ml
    0: 8:36 "sub" "x + 1" -> "x - 1"
    1: 8:25 "sub" "x + 1" -> "x - 1"
    2: 8:18 "not" "c" -> "not c"
    3: 9:21 "le" "a < b" -> "a <= b"
    4: 10:19 "not" "f (x + 1)" -> "not (f (x + 1))"
    5: 10:21 "sub" "x + 1" -> "x - 1"
    6: 11:20 "or" "a && b" -> "a || b"
    7: 12:17 "not" "c" -> "not c"
    8: 13:16 "not" "c" -> "not c"
    9: 14:18 "not" "c" -> "not c"
    10: 16:5 "not" "c" -> "not c"
    11: 17:21 "neq" "a = b" -> "a <> b"
  $ sites --impl ./fixture_equivalent_arm.ml
    0: 9:20 "drop" "| `A -> ..." -> "| `A when false -> ..."
    1: 9:30 "drop" "| _ -> ..." -> "| _ when false -> ..."
    2: 10:21 "drop" "| Some _x -> ..." -> "| Some _x when false -> ..."
    3: 10:36 "drop" "| _ -> ..." -> "| _ when false -> ..."
    4: 11:25 "drop" "| `A when p -> ..." -> "| `A when false -> ..."
    5: 11:33 "not" "p" -> "not p"
    6: 11:42 "drop" "| _ -> ..." -> "| _ when false -> ..."
    7: 12:21 "drop" "| `A -> ..." -> "| `A when false -> ..."
    8: 12:31 "drop" "| x -> ..." -> "| x when false -> ..."
    9: 12:36 "skip" "ignore x" -> "()"
    10: 13:22 "drop" "| `A -> ..." -> "| `A when false -> ..."
    11: 13:35 "drop" "| _ -> ..." -> "| _ when false -> ..."
    12: 14:30 "drop" "| Not_found -> ..." -> "| Not_found when false -> ..."
    13: 14:47 "drop" "| _ -> ..." -> "| _ when false -> ..."
    14: 16:27 "drop" "| exception Not_found -> ..." -> "| exception Not_found when false -> ..."
    15: 16:54 "drop" "| exception _ -> ..." -> "| exception _ when false -> ..."
    16: 17:22 "drop" "| (lazy 0) -> ..." -> "| (lazy 0) when false -> ..."
    17: 17:36 "drop" "| _ -> ..." -> "| _ when false -> ..."
    18: 18:30 "drop" "| `A -> ..." -> "| `A when false -> ..."
    19: 18:40 "drop" "| _ when p -> ..." -> "| _ when false -> ..."
    20: 18:47 "not" "p" -> "not p"
    21: 19:30 "drop" "| exception Not_found -> ..." -> "| exception Not_found when false -> ..."
    22: 20:28 "drop" "| 1 -> ..." -> "| 1 when false -> ..."
    23: 20:37 "drop" "| 2 -> ..." -> "| 2 when false -> ..."
    24: 20:46 "drop" "| exception _ -> ..." -> "| exception _ when false -> ..."
  $ sites --impl ./fixture_equivalent_log.ml
    0: 8:45 "sub" "x + 1" -> "x - 1"
    1: 8:70 "none" "Some x" -> "None"
    2: 9:42 "add" "x - 1" -> "x + 1"
    3: 10:33 "sub" "x + 1" -> "x - 1"
    4: 13:2 "skip" "Log.debug (fun m -> m \"%d\" (x + 1))" -> "()"
    5: 13:29 "sub" "x + 1" -> "x - 1"
    6: 16:38 "sub" "x + 1" -> "x - 1"
    7: 17:38 "sub" "x + 1" -> "x - 1"
    8: 18:40 "sub" "x + 1" -> "x - 1"
    9: 19:48 "sub" "x + 1" -> "x - 1"
    10: 22:2 "skip" "Logs.debug (fun m -> y := ((!y) + 1); (let () = incr y in m \"%d\" (!y)))" -> "()"
    11: 23:6 "skip" "y := ((!y) + 1)" -> "()"
    12: 23:11 "sub" "(!y) + 1" -> "(!y) - 1"
    13: 24:15 "skip" "incr y" -> "()"
    14: 26:2 "sub" "(!y) + x" -> "(!y) - x"
  $ sites -lit --impl ./fixture_equivalent_lit.ml
    0: 8:54 "sub" "n + 1" -> "n - 1"
    1: 8:59 "inc" "1" -> "2"
    2: 8:62 "inc" "10" -> "11"
    3: 9:51 "inc" "3" -> "4"
    4: 10:54 "inc" "4" -> "5"
    5: 11:29 "inc" "5" -> "6"
    6: 12:55 "inc" "6" -> "7"
    7: 13:56 "inc" "8" -> "9"
    8: 14:50 "inc" "9" -> "10"
    9: 15:38 "one" "0" -> "1"
    10: 16:44 "zero" "2.5" -> "0."
    11: 17:46 "one" "0." -> "1."
    12: 18:39 "flip" "true" -> "false"
    13: 19:25 "skip" "r := 5" -> "()"
    14: 19:30 "inc" "5" -> "6"
    15: 20:36 "skip" "r := 7" -> "()"
    16: 20:41 "inc" "7" -> "8"

  $ mut --impl ./fixture_exclude.ml | ../elide.exe
  [@@@mutate exclude_file]
  let sum a b = a + b
  let ordered a b = if a < b then 1 else 0

Each backend flag switches one family off or on:

  $ mut -no-arm --impl ./fixture_flags.ml | ../elide.exe
  mutation sites of "./fixture_flags.ml" in Windtrap_mut_________fixture_flags___ml:
    0: 7:2 "skip" "incr r" -> "()"
    1: 8:2 "sub" "(!r) + 1" -> "(!r) - 1"
    2: 10:13 "none" "Some x" -> "None"
  let size n = match n with | 0 -> "none" | _ -> "some"
  let tick r =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 0)
    then (incr r; ());
    (let (__windtrap_mut_1_l, __windtrap_mut_1_r) = ((!r), 1) in
     if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 1
     then __windtrap_mut_1_l - __windtrap_mut_1_r
     else __windtrap_mut_1_l + __windtrap_mut_1_r)
  let wrap x =
    if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 2
    then None
    else Some x

  $ mut -no-call --impl ./fixture_flags.ml | ../elide.exe
  mutation sites of "./fixture_flags.ml" in Windtrap_mut_________fixture_flags___ml:
    0: 4:26 "drop" "| 0 -> ..." -> "| 0 when false -> ..."
    1: 4:40 "drop" "| _ -> ..." -> "| _ when false -> ..."
    2: 8:2 "sub" "(!r) + 1" -> "(!r) - 1"
    3: 10:13 "none" "Some x" -> "None"
  let size n =
    ((match n with
      | 0 when
          if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 0
          then false
          else true -> "none"
      | _ when
          if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 1
          then false
          else true -> "some")
    [@ocaml.warning "-8-57"])
  let tick r =
    incr r;
    (let (__windtrap_mut_2_l, __windtrap_mut_2_r) = ((!r), 1) in
     if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 2
     then __windtrap_mut_2_l - __windtrap_mut_2_r
     else __windtrap_mut_2_l + __windtrap_mut_2_r)
  let wrap x =
    if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 3
    then None
    else Some x

  $ mut -no-ret --impl ./fixture_flags.ml | ../elide.exe
  mutation sites of "./fixture_flags.ml" in Windtrap_mut_________fixture_flags___ml:
    0: 4:26 "drop" "| 0 -> ..." -> "| 0 when false -> ..."
    1: 4:40 "drop" "| _ -> ..." -> "| _ when false -> ..."
    2: 7:2 "skip" "incr r" -> "()"
    3: 8:2 "sub" "(!r) + 1" -> "(!r) - 1"
  let size n =
    ((match n with
      | 0 when
          if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 0
          then false
          else true -> "none"
      | _ when
          if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 1
          then false
          else true -> "some")
    [@ocaml.warning "-8-57"])
  let tick r =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 2)
    then (incr r; ());
    (let (__windtrap_mut_3_l, __windtrap_mut_3_r) = ((!r), 1) in
     if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 3
     then __windtrap_mut_3_l - __windtrap_mut_3_r
     else __windtrap_mut_3_l + __windtrap_mut_3_r)
  let wrap x = Some x

  $ mut -lit --impl ./fixture_flags.ml | ../elide.exe
  mutation sites of "./fixture_flags.ml" in Windtrap_mut_________fixture_flags___ml:
    0: 4:26 "drop" "| 0 -> ..." -> "| 0 when false -> ..."
    1: 4:40 "drop" "| _ -> ..." -> "| _ when false -> ..."
    2: 7:2 "skip" "incr r" -> "()"
    3: 8:2 "sub" "(!r) + 1" -> "(!r) - 1"
    4: 8:7 "inc" "1" -> "2"
    5: 10:13 "none" "Some x" -> "None"
  let size n =
    ((match n with
      | 0 when
          if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 0
          then false
          else true -> "none"
      | _ when
          if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 1
          then false
          else true -> "some")
    [@ocaml.warning "-8-57"])
  let tick r =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 2)
    then (incr r; ());
    (let (__windtrap_mut_3_l, __windtrap_mut_3_r) =
       ((!r),
         (if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 4
          then 2
          else 1)) in
     if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 3
     then __windtrap_mut_3_l - __windtrap_mut_3_r
     else __windtrap_mut_3_l + __windtrap_mut_3_r)
  let wrap x =
    if Windtrap_mut_________fixture_flags___ml.___windtrap_armed___ 5
    then None
    else Some x

  $ mut --impl ./fixture_inline_tests.ml | ../elide.exe
  mutation sites of "./fixture_inline_tests.ml" in Windtrap_mut_________fixture_inline_tests___ml, with type 'a operands:
    0: 6:14 "sub" "a + b" -> "a - b"
    1: 7:21 "le" "a < b" -> "a <= b"
  let sum a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_inline_tests___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r
  let ordered a b =
    if
      let (__windtrap_mut_1_l, __windtrap_mut_1_r) =
        ((a, b) : _ Windtrap_mut_________fixture_inline_tests___ml.operands) in
      (if Windtrap_mut_________fixture_inline_tests___ml.___windtrap_armed___ 1
       then Stdlib.not (__windtrap_mut_1_r < __windtrap_mut_1_l)
       else __windtrap_mut_1_l < __windtrap_mut_1_r)
    then 1
    else 0
  [%%test let "sums" = if (sum 1 2) = 3 then () else failwith "sum"]
  [%%test
    module Grouped =
      struct
        let twice x = x + x
        [%%test
          let "orders" =
            if (ordered 1 (twice 1)) > 0 then () else failwith "order"]
      end]
  [%%expect_test let "prints" = print_int ((sum 1 2) - 1); [%expect {| 2 |}]]

  $ ../pp.exe -apply ppx_windtrap,windtrap_mutate --impl ./fixture_inline_tests.ml | ../elide.exe
  mutation sites of "./fixture_inline_tests.ml" in Windtrap_mut_________fixture_inline_tests___ml, with type 'a operands:
    0: 6:14 "sub" "a + b" -> "a - b"
    1: 7:21 "le" "a < b" -> "a <= b"
  let sum a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_inline_tests___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r
  let ordered a b =
    if
      let (__windtrap_mut_1_l, __windtrap_mut_1_r) =
        ((a, b) : _ Windtrap_mut_________fixture_inline_tests___ml.operands) in
      (if Windtrap_mut_________fixture_inline_tests___ml.___windtrap_armed___ 1
       then Stdlib.not (__windtrap_mut_1_r < __windtrap_mut_1_l)
       else __windtrap_mut_1_l < __windtrap_mut_1_r)
    then 1
    else 0
  let () =
    Ppx_windtrap_runtime.Ppx_runtime.add_test ~file:"./fixture_inline_tests.ml"
      ~pos:("./fixture_inline_tests.ml", 8, 0, 60) ~tags:[] "sums"
      (fun () ->
         match (if (sum 1 2) = 3 then () else failwith "sum" : unit) with
         | () -> ()
         | exception __windtrap_e -> Stdlib.raise_notrace __windtrap_e)
    [@@windtrap.test ]
  let () =
    Ppx_windtrap_runtime.Ppx_runtime.enter_group
      ~file:"./fixture_inline_tests.ml" ~tags:[] "Grouped"[@@windtrap.test ]
  module Grouped =
    struct
      let twice x = x + x
      let () =
        Ppx_windtrap_runtime.Ppx_runtime.add_test
          ~file:"./fixture_inline_tests.ml"
          ~pos:("./fixture_inline_tests.ml", 12, 2, 78) ~tags:[] "orders"
          (fun () ->
             match (if (ordered 1 (twice 1)) > 0 then () else failwith "order" : 
               unit)
             with
             | () -> ()
             | exception __windtrap_e -> Stdlib.raise_notrace __windtrap_e)
        [@@windtrap.test ]
    end[@@windtrap.test ]
  let () = Ppx_windtrap_runtime.Ppx_runtime.leave_group ()[@@windtrap.test ]
  let () =
    Ppx_windtrap_runtime.Ppx_runtime.add_test ~file:"./fixture_inline_tests.ml"
      ~pos:("./fixture_inline_tests.ml", 15, 0, 73) ~tags:[] "prints"
      (fun () ->
         Ppx_windtrap_runtime.Ppx_runtime.expect_test
           ~pos:("./fixture_inline_tests.ml", 15, 0, 73)
           ~body_end:("./fixture_inline_tests.ml", 17, 19, 19)
           ~nodes:[("./fixture_inline_tests.ml", 17, 2, 19)]
           (fun () ->
              (Expect_test_config.run : (unit -> unit) -> unit)
                (fun () ->
                   match (print_int ((sum 1 2) - 1);
                          Ppx_windtrap_runtime.Ppx_runtime.reach
                            ("./fixture_inline_tests.ml", 17, 2, 19);
                          Windtrap.expect
                            (Expect_test_config.sanitize (Windtrap.output ()))
                            (("./fixture_inline_tests.ml", 17, 2, 19), {| 2 |}) : 
                     unit)
                   with
                   | () -> ()
                   | exception __windtrap_e ->
                       Stdlib.raise_notrace __windtrap_e))
           (fun () -> Expect_test_config.sanitize (Windtrap.output ())))
    [@@windtrap.test ]

  $ mut --impl ./fixture_lazy.ml | ../elide.exe
  mutation sites of "./fixture_lazy.ml" in Windtrap_mut_________fixture_lazy___ml:
    0: 10:22 "sub" "a + b" -> "a - b"
    1: 17:25 "sub" "a + b" -> "a - b"
  let thunk a b = lazy (fun () -> a + b)
  let forced a b =
    lazy
      (let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
       if Windtrap_mut_________fixture_lazy___ml.___windtrap_armed___ 0
       then __windtrap_mut_0_l - __windtrap_mut_0_r
       else __windtrap_mut_0_l + __windtrap_mut_0_r)
  let plain x = lazy x
  let annotated a b = lazy (fun () -> a + b : unit -> int)
  let computed a b =
    lazy
      (let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (a, b) in
       if Windtrap_mut_________fixture_lazy___ml.___windtrap_armed___ 1
       then __windtrap_mut_1_l - __windtrap_mut_1_r
       else __windtrap_mut_1_l + __windtrap_mut_1_r : int)

  $ mut --impl ./fixture_lazy_condition.ml | ../elide.exe
  mutation sites of "./fixture_lazy_condition.ml" in Windtrap_mut_________fixture_lazy_condition___ml:
    0: 4:17 "not" "x" -> "not x"
  let deferred x = if lazy x then 1 else 0
  let plain x =
    if
      let __windtrap_mut_0_p = x in
      (if
         Windtrap_mut_________fixture_lazy_condition___ml.___windtrap_armed___
           0
       then Stdlib.not __windtrap_mut_0_p
       else __windtrap_mut_0_p)
    then 1
    else 0

  $ mut --impl ./fixture_lost_ret.ml | ../elide.exe
  type found =
    | Some of int 
    | Missing 
  let found n = Some n
  let push x xs = x :: xs

  $ mut --impl ./fixture_lost_ret_none.ml | ../elide.exe
  mutation sites of "./fixture_lost_ret_none.ml" in Windtrap_mut_________fixture_lost_ret_none___ml:
    0: 9:14 "sub" "a + b" -> "a - b"
  type outcome =
    | None 
    | Other 
  let found n = Some n
  let push x xs = x :: xs
  let sum a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_lost_ret_none___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r

  $ mut --impl ./fixture_lost_ret_cons.ml | ../elide.exe
  mutation sites of "./fixture_lost_ret_cons.ml" in Windtrap_mut_________fixture_lost_ret_cons___ml:
    0: 8:14 "sub" "a + b" -> "a - b"
  type pair =
    | (::) of int * string 
  let pair n s = n :: s
  let found n = Some n
  let sum a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_lost_ret_cons___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r

  $ mut -lit --impl ./fixture_lost_flip.ml | ../elide.exe
  mutation sites of "./fixture_lost_flip.ml" in Windtrap_mut_________fixture_lost_flip___ml:
    0: 8:11 "inc" "3" -> "4"
  type truth =
    | true 
    | Unknown 
  let sure : truth = true
  let size =
    if Windtrap_mut_________fixture_lost_flip___ml.___windtrap_armed___ 0
    then 4
    else 3

  $ mut --impl ./fixture_lost_arm.ml | ../elide.exe
  mutation sites of "./fixture_lost_arm.ml" in Windtrap_mut_________fixture_lost_arm___ml:
    0: 8:14 "sub" "a + b" -> "a - b"
  type answer =
    | false 
    | true 
  let size n = match n with | 0 -> "none" | _ -> "some"
  let sum a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_lost_arm___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r

  $ mut --impl ./fixture_lost_arm_true.ml | ../elide.exe
  mutation sites of "./fixture_lost_arm_true.ml" in Windtrap_mut_________fixture_lost_arm_true___ml:
    0: 6:14 "sub" "a + b" -> "a - b"
  type answer =
    | true 
  let size n = match n with | 0 -> "none" | _ -> "some"
  let sum a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_lost_arm_true___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r

  $ mut --impl ./fixture_lost_arm_false.ml | ../elide.exe
  mutation sites of "./fixture_lost_arm_false.ml" in Windtrap_mut_________fixture_lost_arm_false___ml:
    0: 6:14 "sub" "a + b" -> "a - b"
  type answer =
    | false 
  let size n = match n with | 0 -> "none" | _ -> "some"
  let sum a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_lost_arm_false___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r

  $ mut --impl ./fixture_lost_call.ml | ../elide.exe
  type t =
    | () 
  let run f x = let () = f x in f x; x

  $ mut --impl ./fixture_lost_extension.ml | ../elide.exe
  type e = ..
  type e +=  
    | () 
    | false 
    | true 
    | None 
  let run f x = f x; (match x with | 0 -> "none" | _ -> "some")
  let found n = Some n

  $ mut --impl ./fixture_lost_cmp.ml | ../elide.exe
  mutation sites of "./fixture_lost_cmp.ml" in Windtrap_mut_________fixture_lost_cmp___ml:
    0: 11:43 "add" "a - b" -> "a + b"
    1: 11:32 "sub" "a + b" -> "a - b"
    2: 11:21 "not" "a < b" -> "not (a < b)"
    3: 12:18 "or" "a && b" -> "a || b"
    4: 14:2 "skip" "a < b" -> "()"
  let (<=) a b = (compare a b) <= 0
  let not b = b
  let ordered a b =
    if
      let __windtrap_mut_2_p = a < b in
      (if Windtrap_mut_________fixture_lost_cmp___ml.___windtrap_armed___ 2
       then Stdlib.not __windtrap_mut_2_p
       else __windtrap_mut_2_p)
    then
      let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (a, b) in
      (if Windtrap_mut_________fixture_lost_cmp___ml.___windtrap_armed___ 1
       then __windtrap_mut_1_l - __windtrap_mut_1_r
       else __windtrap_mut_1_l + __windtrap_mut_1_r)
    else
      (let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
       if Windtrap_mut_________fixture_lost_cmp___ml.___windtrap_armed___ 0
       then __windtrap_mut_0_l + __windtrap_mut_0_r
       else __windtrap_mut_0_l - __windtrap_mut_0_r)
  let both a b =
    if
      let __windtrap_mut_3_p = a in
      (if
         Stdlib.(<>) (__windtrap_mut_3_p : Stdlib.Bool.t)
           (Windtrap_mut_________fixture_lost_cmp___ml.___windtrap_armed___ 3)
       then b
       else __windtrap_mut_3_p)
    then 1
    else 0
  let compare_only a b =
    if
      Stdlib.not
        (Windtrap_mut_________fixture_lost_cmp___ml.___windtrap_armed___ 4)
    then (a < b; ());
    ()

  $ mut --impl ./fixture_lost_con.ml | ../elide.exe
  mutation sites of "./fixture_lost_con.ml" in Windtrap_mut_________fixture_lost_con___ml, with type 'a operands:
    0: 11:18 "not" "a && b" -> "not (a && b)"
    1: 12:20 "not" "a || b" -> "not (a || b)"
    2: 13:24 "not" "(a < b) && c" -> "not ((a < b) && c)"
    3: 14:43 "add" "a - b" -> "a + b"
    4: 14:32 "sub" "a + b" -> "a - b"
    5: 14:21 "le" "a < b" -> "a <= b"
  external (&&) : bool -> bool -> bool = "%sequand"
  let both a b =
    if
      let __windtrap_mut_0_p = a && b in
      (if Windtrap_mut_________fixture_lost_con___ml.___windtrap_armed___ 0
       then Stdlib.not __windtrap_mut_0_p
       else __windtrap_mut_0_p)
    then 1
    else 0
  let either a b =
    if
      let __windtrap_mut_1_p = a || b in
      (if Windtrap_mut_________fixture_lost_con___ml.___windtrap_armed___ 1
       then Stdlib.not __windtrap_mut_1_p
       else __windtrap_mut_1_p)
    then 1
    else 0
  let compared a b c =
    if
      let __windtrap_mut_2_p = (a < b) && c in
      (if Windtrap_mut_________fixture_lost_con___ml.___windtrap_armed___ 2
       then Stdlib.not __windtrap_mut_2_p
       else __windtrap_mut_2_p)
    then 1
    else 0
  let ordered a b =
    if
      let (__windtrap_mut_5_l, __windtrap_mut_5_r) =
        ((a, b) : _ Windtrap_mut_________fixture_lost_con___ml.operands) in
      (if Windtrap_mut_________fixture_lost_con___ml.___windtrap_armed___ 5
       then Stdlib.not (__windtrap_mut_5_r < __windtrap_mut_5_l)
       else __windtrap_mut_5_l < __windtrap_mut_5_r)
    then
      let (__windtrap_mut_4_l, __windtrap_mut_4_r) = (a, b) in
      (if Windtrap_mut_________fixture_lost_con___ml.___windtrap_armed___ 4
       then __windtrap_mut_4_l - __windtrap_mut_4_r
       else __windtrap_mut_4_l + __windtrap_mut_4_r)
    else
      (let (__windtrap_mut_3_l, __windtrap_mut_3_r) = (a, b) in
       if Windtrap_mut_________fixture_lost_con___ml.___windtrap_armed___ 3
       then __windtrap_mut_3_l + __windtrap_mut_3_r
       else __windtrap_mut_3_l - __windtrap_mut_3_r)

  $ mut --impl ./fixture_neg.ml | ../elide.exe
  mutation sites of "./fixture_neg.ml" in Windtrap_mut_________fixture_neg___ml:
    0: 8:23 "not" "flag" -> "not flag"
    1: 9:23 "not" "flag" -> "not flag"
    2: 12:8 "not" "ready ()" -> "not (ready ())"
    3: 16:32 "drop" "| y when p y -> ..." -> "| y when false -> ..."
    4: 16:39 "not" "p y" -> "not (p y)"
    5: 16:54 "drop" "| _ -> ..." -> "| _ when false -> ..."
    6: 20:20 "not" "if a then b else false" -> "not (if a then b else false)"
    7: 20:23 "not" "a" -> "not a"
  let pick flag x y =
    if
      let __windtrap_mut_0_p = flag in
      (if Windtrap_mut_________fixture_neg___ml.___windtrap_armed___ 0
       then Stdlib.not __windtrap_mut_0_p
       else __windtrap_mut_0_p)
    then x
    else y
  let announce flag =
    if
      let __windtrap_mut_1_p = flag in
      (if Windtrap_mut_________fixture_neg___ml.___windtrap_armed___ 1
       then Stdlib.not __windtrap_mut_1_p
       else __windtrap_mut_1_p)
    then print_string "on"
  let drain ready step =
    while
      let __windtrap_mut_2_p = ready () in
      if Windtrap_mut_________fixture_neg___ml.___windtrap_armed___ 2
      then Stdlib.not __windtrap_mut_2_p
      else __windtrap_mut_2_p do step () done
  let classify p x =
    ((match x with
      | y when
          if Windtrap_mut_________fixture_neg___ml.___windtrap_armed___ 3
          then false
          else
            (let __windtrap_mut_4_p = p y in
             if Windtrap_mut_________fixture_neg___ml.___windtrap_armed___ 4
             then Stdlib.not __windtrap_mut_4_p
             else __windtrap_mut_4_p)
          -> "yes"
      | _ when
          if Windtrap_mut_________fixture_neg___ml.___windtrap_armed___ 5
          then false
          else true -> "no")
    [@ocaml.warning "-8-57"])
  let nested a b =
    if
      let __windtrap_mut_6_p =
        if
          let __windtrap_mut_7_p = a in
          (if Windtrap_mut_________fixture_neg___ml.___windtrap_armed___ 7
           then Stdlib.not __windtrap_mut_7_p
           else __windtrap_mut_7_p)
        then b
        else false in
      (if Windtrap_mut_________fixture_neg___ml.___windtrap_armed___ 6
       then Stdlib.not __windtrap_mut_6_p
       else __windtrap_mut_6_p)
    then 1
    else 0

  $ mut --impl ./fixture_nesting.ml | ../elide.exe
  mutation sites of "./fixture_nesting.ml" in Windtrap_mut_________fixture_nesting___ml, with type 'a operands:
    0: 6:23 "or" "b && c" -> "b || c"
    1: 7:18 "or" "a && b" -> "a || b"
    2: 8:30 "and" "c || d" -> "c && d"
    3: 11:20 "le" "a < b" -> "a <= b"
    4: 12:20 "or" "a && b" -> "a || b"
    5: 13:18 "not" "a" -> "not a"
  let chain a b c =
    a &&
      (let __windtrap_mut_0_p = b in
       if
         Stdlib.(<>) (__windtrap_mut_0_p : Stdlib.Bool.t)
           (Windtrap_mut_________fixture_nesting___ml.___windtrap_armed___ 0)
       then c
       else __windtrap_mut_0_p)
  let mixed a b c =
    (let __windtrap_mut_1_p = a in
     if
       Stdlib.(<>) (__windtrap_mut_1_p : Stdlib.Bool.t)
         (Windtrap_mut_________fixture_nesting___ml.___windtrap_armed___ 1)
     then b
     else __windtrap_mut_1_p) || c
  let deep a b c d =
    a ||
      (b &&
         (let __windtrap_mut_2_p = c in
          if
            Stdlib.(=) (__windtrap_mut_2_p : Stdlib.Bool.t)
              (Windtrap_mut_________fixture_nesting___ml.___windtrap_armed___ 2)
          then d
          else __windtrap_mut_2_p))
  let by_cmp a b =
    if
      let (__windtrap_mut_3_l, __windtrap_mut_3_r) =
        ((a, b) : _ Windtrap_mut_________fixture_nesting___ml.operands) in
      (if Windtrap_mut_________fixture_nesting___ml.___windtrap_armed___ 3
       then Stdlib.not (__windtrap_mut_3_r < __windtrap_mut_3_l)
       else __windtrap_mut_3_l < __windtrap_mut_3_r)
    then 1
    else 0
  let by_con a b =
    if
      let __windtrap_mut_4_p = a in
      (if
         Stdlib.(<>) (__windtrap_mut_4_p : Stdlib.Bool.t)
           (Windtrap_mut_________fixture_nesting___ml.___windtrap_armed___ 4)
       then b
       else __windtrap_mut_4_p)
    then 1
    else 0
  let by_neg a =
    if
      let __windtrap_mut_5_p = a in
      (if Windtrap_mut_________fixture_nesting___ml.___windtrap_armed___ 5
       then Stdlib.not __windtrap_mut_5_p
       else __windtrap_mut_5_p)
    then 1
    else 0

  $ mut --impl ./fixture_off.ml | ../elide.exe
  mutation sites of "./fixture_off.ml" in Windtrap_mut_________fixture_off___ml:
    0: 9:5 "ge" "want > 16" -> "want >= 16", dismissed "both arms yield 16 at the boundary"
    1: 12:19 "or" "a && b" -> "a || b", dismissed ""
    2: 26:18 "sub" "a + b" -> "a - b"
  let cap want =
    if ((want > 16)[@mutate off "both arms yield 16 at the boundary"])
    then want
    else 16
  let plain a b = if ((a && b)[@mutate off]) then 1 else 0
  let sum a b = a + b[@@mutate off]
  module Hidden = struct let diff a b = a - b end[@@mutate off]
  [@@@mutate off]
  let suppressed a b = a + b
  [@@@mutate on]
  let visible a b =
    let (__windtrap_mut_2_l, __windtrap_mut_2_r) = (a, b) in
    if Windtrap_mut_________fixture_off___ml.___windtrap_armed___ 2
    then __windtrap_mut_2_l - __windtrap_mut_2_r
    else __windtrap_mut_2_l + __windtrap_mut_2_r

  $ mut --impl ./fixture_off_edges.ml | ../elide.exe
  mutation sites of "./fixture_off_edges.ml" in Windtrap_mut_________fixture_off_edges___ml:
    0: 15:4 "ge" "want > 16" -> "want >= 16", dismissed "a \"quoted\" reason,\nspanning lines \\ containing a backslash"
    1: 30:10 "sub" "a + b" -> "a - b"
    2: 39:16 "sub" "a + b" -> "a - b"
  let quoted want =
    if ((want > 16)
      [@mutate
        off "a \"quoted\" reason,\nspanning lines \\ containing a backslash"])
    then want
    else 16
  let coarse a b = ((match a with | 0 -> b | n -> n + b)
    [@mutate off "not a site"])
  let local a b =
    let s =
      let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (a, b) in
      if Windtrap_mut_________fixture_off_edges___ml.___windtrap_armed___ 1
      then __windtrap_mut_1_l - __windtrap_mut_1_r
      else __windtrap_mut_1_l + __windtrap_mut_1_r[@@mutate off "ignored here"] in
    s
  type t = int[@@mutate off]
  let after a b =
    let (__windtrap_mut_2_l, __windtrap_mut_2_r) = (a, b) in
    if Windtrap_mut_________fixture_off_edges___ml.___windtrap_armed___ 2
    then __windtrap_mut_2_l - __windtrap_mut_2_r
    else __windtrap_mut_2_l + __windtrap_mut_2_r

  $ mut --impl ./fixture_off_structure.ml | ../elide.exe
  mutation sites of "./fixture_off_structure.ml" in Windtrap_mut_________fixture_off_structure___ml:
    0: 16:12 "add" "x - 1" -> "x + 1"
    1: 41:23 "sub" "a + b" -> "a - b"
    2: 48:14 "sub" "a + b" -> "a - b"
  module rec Dark:sig val f : int -> int end = struct let f n = n + 1 end
  [@@mutate off]
  
  let local n =
    let h x =
      let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (x, 1) in
      if Windtrap_mut_________fixture_off_structure___ml.___windtrap_armed___ 0
      then __windtrap_mut_0_l + __windtrap_mut_0_r
      else __windtrap_mut_0_l - __windtrap_mut_0_r[@@mutate bogus] in
    h n
  type t = int[@@mutate bogus]
  let reasoned a b = a + b[@@mutate off "binding reason"]
  [@@@mutate off "region reason"]
  let in_region a b = a - b
  [@@@mutate on]
  [@@@mutate off]
  module Inherits =
    struct
      let dark a b = a + b
      [@@@mutate on]
      let lit_inside a b =
        let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (a, b) in
        if
          Windtrap_mut_________fixture_off_structure___ml.___windtrap_armed___
            1
        then __windtrap_mut_1_l - __windtrap_mut_1_r
        else __windtrap_mut_1_l + __windtrap_mut_1_r
    end
  let still_dark a b = a + b
  [@@@mutate on]
  let lit a b =
    let (__windtrap_mut_2_l, __windtrap_mut_2_r) = (a, b) in
    if Windtrap_mut_________fixture_off_structure___ml.___windtrap_armed___ 2
    then __windtrap_mut_2_l - __windtrap_mut_2_r
    else __windtrap_mut_2_l + __windtrap_mut_2_r

  $ mut --impl ./fixture_off_unclosed.ml | ../elide.exe
  mutation sites of "./fixture_off_unclosed.ml" in Windtrap_mut_________fixture_off_unclosed___ml:
    0: 17:18 "sub" "a + b" -> "a - b"
  module Quiet = struct [@@@mutate off]
                        let hidden a b = a + b end
  let visible a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_off_unclosed___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r
  [@@@mutate off]
  let suppressed a b = a + b
  let also_suppressed a b = if a && b then 1 else 0

  $ mut --impl ./fixture_payloads.ml | ../elide.exe
  mutation sites of "./fixture_payloads.ml" in Windtrap_mut_________fixture_payloads___ml:
    0: 6:18 "sub" "a + b" -> "a - b"
  let extended = [%ext a + b]
  let attributed = ((0)[@attr a + b])
  let written a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_payloads___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l - __windtrap_mut_0_r
    else __windtrap_mut_0_l + __windtrap_mut_0_r

  $ mut --impl ./fixture_shadow.ml | ../elide.exe
  mutation sites of "./fixture_shadow.ml" in Windtrap_mut_________fixture_shadow___ml, with type 'a operands:
    0: 16:21 "le" "a < b" -> "a <= b"
    1: 17:15 "or" "a && b" -> "a || b"
  module Vec =
    struct
      type t = {
        x: int ;
        y: int }
      let (+) a b = { x = (a.x + b.x); y = (a.y + b.y) }
    end
  let move a b = Vec.(+) a b
  let ordered a b =
    if
      let (__windtrap_mut_0_l, __windtrap_mut_0_r) =
        ((a, b) : _ Windtrap_mut_________fixture_shadow___ml.operands) in
      (if Windtrap_mut_________fixture_shadow___ml.___windtrap_armed___ 0
       then Stdlib.not (__windtrap_mut_0_r < __windtrap_mut_0_l)
       else __windtrap_mut_0_l < __windtrap_mut_0_r)
    then 1
    else 0
  let both a b =
    let __windtrap_mut_1_p = a in
    if
      Stdlib.(<>) (__windtrap_mut_1_p : Stdlib.Bool.t)
        (Windtrap_mut_________fixture_shadow___ml.___windtrap_armed___ 1)
    then b
    else __windtrap_mut_1_p
  let untouched a b = a - b

  $ mut --impl ./fixture_texts.ml | ../elide.exe
  mutation sites of "./fixture_texts.ml" in Windtrap_mut_________fixture_texts___ml, with type 'a operands:
    0: 6:18 "neq" "s = \"a b\"" -> "s <> \"a b\""
    1: 10:15 "sub" "a + b" -> "a - b"
    2: 11:22 "le" "a < b" -> "a <= b"
  let spaced s =
    if
      let __windtrap_mut_0_p = s = "a   b" in
      (if Windtrap_mut_________fixture_texts___ml.___windtrap_armed___ 0
       then Stdlib.not __windtrap_mut_0_p
       else __windtrap_mut_0_p)
    then 1
    else 0
  let kept a b =
    let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (a, b) in
    if Windtrap_mut_________fixture_texts___ml.___windtrap_armed___ 1
    then __windtrap_mut_1_l - __windtrap_mut_1_r
    else ((__windtrap_mut_1_l + __windtrap_mut_1_r)[@kept ])
  let kept_cmp a b =
    if
      let (__windtrap_mut_2_l, __windtrap_mut_2_r) =
        ((a, b) : _ Windtrap_mut_________fixture_texts___ml.operands) in
      (if Windtrap_mut_________fixture_texts___ml.___windtrap_armed___ 2
       then Stdlib.not (__windtrap_mut_2_r < __windtrap_mut_2_l)
       else ((__windtrap_mut_2_l < __windtrap_mut_2_r)[@kept ]))
    then 1
    else 0

Over code a deriver generated, for which generated.ml stands in:

  $ ../pp.exe -apply windtrap_test_generated,windtrap_mutate --impl ./fixture_generated.ml | ../elide.exe
  mutation sites of "./fixture_generated.ml" in Windtrap_mut_________fixture_generated___ml:
    0: 6:18 "add" "a - b" -> "a + b"
    1: 11:21 "sub" "a + b" -> "a - b"
    2: 16:49 "drop" "| None -> ..." -> "| None when false -> ..."
    3: 20:28 "drop" "| Some x -> ..." -> "| Some x when false -> ..."
    4: 20:42 "drop" "| None -> ..." -> "| None when false -> ..."
  let generated a b = ((a + b)[@generated ])
  let written a b =
    let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
    if Windtrap_mut_________fixture_generated___ml.___windtrap_armed___ 0
    then __windtrap_mut_0_l + __windtrap_mut_0_r
    else __windtrap_mut_0_l - __windtrap_mut_0_r
  let copied a b =
    a *
      (let (__windtrap_mut_1_l, __windtrap_mut_1_r) = (a, b) in
       if Windtrap_mut_________fixture_generated___ml.___windtrap_armed___ 1
       then __windtrap_mut_1_l - __windtrap_mut_1_r
       else __windtrap_mut_1_l + __windtrap_mut_1_r)[@@duplicate ]
  let copied a b = a * (a + b)[@@duplicate ]
  let arms =
    ((function
      | ((Some x)[@generated ]) when true -> x
      | None when
          if Windtrap_mut_________fixture_generated___ml.___windtrap_armed___ 2
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let picked o =
    ((match o with
      | Some x when
          if Windtrap_mut_________fixture_generated___ml.___windtrap_armed___ 3
          then false
          else true -> x
      | None when
          if Windtrap_mut_________fixture_generated___ml.___windtrap_armed___ 4
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])[@@duplicate ]
  let picked o = match o with | Some x -> x | None -> 0[@@duplicate ]

  $ ../pp.exe -apply windtrap_test_generated,windtrap_mutate --impl ./fixture_generated_chain.ml | ../elide.exe
  mutation sites of "./fixture_generated_chain.ml" in Windtrap_mut_________fixture_generated_chain___ml:
    0: 6:23 "sub" "(a + b) + c" -> "(a + b) - c"
  let generated a b c = (((a + b) + c)[@generated ])
  let copied f a b c =
    f
      (let (__windtrap_mut_0_l, __windtrap_mut_0_r) = ((a + b), c) in
       if
         Windtrap_mut_________fixture_generated_chain___ml.___windtrap_armed___
           0
       then __windtrap_mut_0_l - __windtrap_mut_0_r
       else __windtrap_mut_0_l + __windtrap_mut_0_r)[@@duplicate ]
  let copied f a b c = f ((a + b) + c)[@@duplicate ]

Over a file the coverage rewriter ran on first. pp.exe runs the mutation
rewriter first whatever order -apply names, so this order has its own
driver, coverage_first.exe:

  $ ../coverage_first.exe -apply windtrap_coverage,windtrap_mutate --impl ./fixture_visits.ml | ../elide.exe
  mutation sites of "./fixture_visits.ml" in Windtrap_mut_________fixture_visits___ml, with type 'a operands:
    0: 7:22 "not" "b" -> "not b"
    1: 7:17 "not" "a" -> "not a"
    2: 10:18 "le" "(___windtrap_post_visit___ 2 (f x)) < (___windtrap_post_visit___ 3 (g x))" -> "(___windtrap_post_visit___ 2 (f x)) <= (___windtrap_post_visit___ 3 (g x))"
    3: 16:2 "skip" "___windtrap_post_visit___ 10 (f x)" -> "()"
    4: 17:2 "skip" "___windtrap_post_visit___ 9 (f x)" -> "()", dismissed "the result of f is discarded"
    5: 18:11 "skip" "___windtrap_post_visit___ 7 (f x)" -> "()"
    6: 19:2 "skip" "___windtrap_post_visit___ 8 (incr r)" -> "()"
    7: 24:21 "not" "___windtrap_post_visit___ 12 (f x)" -> "not (___windtrap_post_visit___ 12 (f x))"
    8: 25:21 "not" "___windtrap_post_visit___ 15 (f x)" -> "not (___windtrap_post_visit___ 15 (f x))", dismissed "a timeout ends the loop"
  coverage points of "./fixture_visits.ml" in Windtrap_cov_________fixture_visits___ml, with ___windtrap_post_visit___:
    0: 262-263
    1: 267-268
    2: 362-365
    3: 368-371
    4: 384-385
    5: 377-378
    6: 359-385
    7: 680-683
    8: 689-695
    9: 617-622
    10: 610-613
    11: 610-701
    12: 874-890
    13: 894-896
    14: 868-901
    15: 923-968
    16: 972-974
    17: 917-979
  let either a b =
    ___windtrap_visit___ 0;
    if
      (let __windtrap_mut_1_p = a in
       if Windtrap_mut_________fixture_visits___ml.___windtrap_armed___ 1
       then Stdlib.not __windtrap_mut_1_p
       else __windtrap_mut_1_p)
    then (___windtrap_visit___ 0; true)
    else
      if
        (let __windtrap_mut_0_p = b in
         if Windtrap_mut_________fixture_visits___ml.___windtrap_armed___ 0
         then Stdlib.not __windtrap_mut_0_p
         else __windtrap_mut_0_p)
      then (___windtrap_visit___ 1; true)
      else false
  let lt f g x =
    ___windtrap_visit___ 6;
    if
      (let (__windtrap_mut_2_l, __windtrap_mut_2_r) =
         (((___windtrap_post_visit___ 2 (f x)),
            (___windtrap_post_visit___ 3 (g x))) : _
                                                     Windtrap_mut_________fixture_visits___ml.operands) in
       if Windtrap_mut_________fixture_visits___ml.___windtrap_armed___ 2
       then Stdlib.not (__windtrap_mut_2_r < __windtrap_mut_2_l)
       else __windtrap_mut_2_l < __windtrap_mut_2_r)
    then (___windtrap_visit___ 5; 1)
    else (___windtrap_visit___ 4; 0)
  let tick r f x =
    ___windtrap_visit___ 11;
    if
      Stdlib.not
        (Windtrap_mut_________fixture_visits___ml.___windtrap_armed___ 3)
    then (___windtrap_post_visit___ 10 (f x); ());
    ___windtrap_post_visit___ 9 ((f x)
      [@mutate off "the result of f is discarded"]);
    (let () =
       if
         Stdlib.not
           (Windtrap_mut_________fixture_visits___ml.___windtrap_armed___ 5)
       then ___windtrap_post_visit___ 7 (f x) in
     if
       Stdlib.not
         (Windtrap_mut_________fixture_visits___ml.___windtrap_armed___ 6)
     then (___windtrap_post_visit___ 8 (incr r); ());
     !r)
  let wait f x =
    ___windtrap_visit___ 14;
    while
      (let __windtrap_mut_7_p = ___windtrap_post_visit___ 12 ((f x)[@inlined ]) in
       if Windtrap_mut_________fixture_visits___ml.___windtrap_armed___ 7
       then Stdlib.not __windtrap_mut_7_p
       else __windtrap_mut_7_p)
      do (___windtrap_visit___ 13; ()) done
  let poll f x =
    ___windtrap_visit___ 17;
    while
      ___windtrap_post_visit___ 15 ((f x)
        [@mutate off "a timeout ends the loop"])
      do (___windtrap_visit___ 16; ()) done

A file under an input name that is not a source file's is returned as
parsed:

  $ for name in //toplevel// '(stdin)' lib/.ocamlinit lib/topfind; do
  >   mut -loc-filename "$name" --impl ./fixture_input_name.ml
  > done
  let sign n = if n > 0 then 1 else 0
  let sign n = if n > 0 then 1 else 0
  let sign n = if n > 0 then 1 else 0
  let sign n = if n > 0 then 1 else 0

A refusal is an error located at the attribute, and the driver exits 1:

  $ mut --impl ./reject_bad_payload.ml
  File "./reject_bad_payload.ml", line 1, characters 18-33:
  1 | let f n = (n + 1) [@mutate bogus]
                        ^^^^^^^^^^^^^^^
  Error: Bad payload in mutate attribute.
  [1]

  $ mut --impl ./reject_bad_payload_cases.ml
  File "./reject_bad_payload_cases.ml", line 1, characters 18-33:
  1 | let h x = function[@mutate bogus] 0 -> x | _ -> 2
                        ^^^^^^^^^^^^^^^
  Error: Bad payload in mutate attribute.
  [1]

  $ mut --impl ./reject_double_off.ml
  File "./reject_double_off.ml", line 5, characters 0-15:
  5 | [@@@mutate off]
      ^^^^^^^^^^^^^^^
  Error: Mutation is already off.
  [1]

  $ mut --impl ./reject_empty_payload.ml
  File "./reject_empty_payload.ml", line 1, characters 18-27:
  1 | let f n = (n + 1) [@mutate]
                        ^^^^^^^^^
  Error: Bad payload in mutate attribute.
  [1]

  $ mut --impl ./reject_exclude_file_binding.ml
  File "./reject_exclude_file_binding.ml", line 1, characters 16-39:
  1 | let f n = n + 1 [@@mutate exclude_file]
                      ^^^^^^^^^^^^^^^^^^^^^^^
  Error: mutate exclude_file is not allowed here.
  [1]

  $ mut --impl ./reject_exclude_file_expr.ml
  File "./reject_exclude_file_expr.ml", line 1, characters 18-40:
  1 | let f n = (n + 1) [@mutate exclude_file]
                        ^^^^^^^^^^^^^^^^^^^^^^
  Error: mutate exclude_file is not allowed here.
  [1]

  $ mut --impl ./reject_exclude_file_sub_pattern.ml
  File "./reject_exclude_file_sub_pattern.ml", line 1, characters 31-53:
  1 | let f x = match x with Some (0 [@mutate exclude_file]) -> 1 | _ -> 0
                                     ^^^^^^^^^^^^^^^^^^^^^^
  Error: mutate exclude_file is not allowed here.
  [1]

  $ mut --impl ./reject_misplaced_exclude_file.ml
  File "./reject_misplaced_exclude_file.ml", line 2, characters 2-26:
  2 |   [@@@mutate exclude_file]
        ^^^^^^^^^^^^^^^^^^^^^^^^
  Error: mutate exclude_file is not allowed here.
  [1]

  $ mut --impl ./reject_misplaced_on.ml
  File "./reject_misplaced_on.ml", line 1, characters 18-30:
  1 | let f n = (n + 1) [@mutate on]
                        ^^^^^^^^^^^^
  Error: mutate on is not allowed here.
  [1]

  $ mut --impl ./reject_off_number.ml
  File "./reject_off_number.ml", line 1, characters 18-34:
  1 | let f n = (n + 1) [@mutate off 42]
                        ^^^^^^^^^^^^^^^^
  Error: Bad payload in mutate attribute.
  [1]

  $ mut --impl ./reject_off_or_pattern.ml
  File "./reject_off_or_pattern.ml", line 1, characters 37-60:
  1 | let either x = match x with `A | (`B [@mutate off "the two"]) -> 1 | `C -> 0
                                           ^^^^^^^^^^^^^^^^^^^^^^^
  Error: mutate off is not allowed inside a pattern. Put it on the whole pattern of the case.
  [1]

  $ mut --impl ./reject_off_rewrite.ml
  File "./reject_off_rewrite.ml", line 3, characters 18-51:
  3 | let f n = (n + 1) [@mutate off sub "equal at zero"]
                        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
  Error: Bad payload in mutate attribute.
  [1]

  $ mut --impl ./reject_off_tuple.ml
  File "./reject_off_tuple.ml", line 1, characters 33-55:
  1 | let first x = match x with 0, (b [@mutate off "unused"]) -> b | a, _ -> a
                                       ^^^^^^^^^^^^^^^^^^^^^^
  Error: mutate off is not allowed inside a pattern. Put it on the whole pattern of the case.
  [1]

  $ mut --impl ./reject_off_two_reasons.ml
  File "./reject_off_two_reasons.ml", line 1, characters 18-39:
  1 | let f n = (n + 1) [@mutate off "a" "b"]
                        ^^^^^^^^^^^^^^^^^^^^^
  Error: Bad payload in mutate attribute.
  [1]

  $ mut --impl ./reject_on_assert.ml
  File "./reject_on_assert.ml", line 1, characters 19-31:
  1 | let f x = assert x [@mutate on]
                         ^^^^^^^^^^^^
  Error: mutate on is not allowed here.
  [1]

  $ mut --impl ./reject_on_binding.ml
  File "./reject_on_binding.ml", line 1, characters 16-29:
  1 | let f n = n + 1 [@@mutate on]
                      ^^^^^^^^^^^^^
  Error: mutate on is not allowed here.
  [1]

  $ mut --impl ./reject_on_outside.ml
  File "./reject_on_outside.ml", line 3, characters 0-14:
  3 | [@@@mutate on]
      ^^^^^^^^^^^^^^
  Error: Mutation is already on.
  [1]

  $ mut --impl ./reject_on_pattern.ml
  File "./reject_on_pattern.ml", line 1, characters 26-38:
  1 | let f x = match x with (0 [@mutate on]) -> 1 | _ -> 0
                                ^^^^^^^^^^^^
  Error: mutate on is not allowed here.
  [1]

  $ mut --impl ./reject_on_sub_pattern.ml
  File "./reject_on_sub_pattern.ml", line 1, characters 31-43:
  1 | let f x = match x with Some (0 [@mutate on]) -> 1 | _ -> 0
                                     ^^^^^^^^^^^^
  Error: mutate on is not allowed here.
  [1]

The rewriter reads the attributes inside the pattern of a case only when
the case has a drop mutant. Under -no-arm no case has one, so the files
that it refuses above give no error:

  $ mut -no-arm --impl ./reject_exclude_file_sub_pattern.ml
  let f x = match x with | Some ((0)[@mutate exclude_file]) -> 1 | _ -> 0
  $ mut -no-arm --impl ./reject_off_or_pattern.ml
  let either x =
    match x with | `A | ((`B)[@mutate off "the two"]) -> 1 | `C -> 0
  $ mut -no-arm --impl ./reject_off_tuple.ml
  let first x =
    match x with | (0, ((b)[@mutate off "unused"])) -> b | (a, _) -> a
  $ mut -no-arm --impl ./reject_on_sub_pattern.ml
  let f x = match x with | Some ((0)[@mutate on]) -> 1 | _ -> 0

The one case that a value can reach and a case of a match with a
refutation case have no drop mutant either:

  $ mut --impl ./fixture_inner_unread.ml | ../elide.exe
  mutation sites of "./fixture_inner_unread.ml" in Windtrap_mut_________fixture_inner_unread___ml:
    0: 5:58 "sub" "a + b" -> "a - b"
  let sum p =
    match p with
    | (a, ((b)[@mutate off "unused"])) ->
        let (__windtrap_mut_0_l, __windtrap_mut_0_r) = (a, b) in
        if
          Windtrap_mut_________fixture_inner_unread___ml.___windtrap_armed___ 0
        then __windtrap_mut_0_l - __windtrap_mut_0_r
        else __windtrap_mut_0_l + __windtrap_mut_0_r
  type empty = |
  let get (r : (int, empty) result) =
    match r with | Ok ((0)[@mutate off "zero"]) -> 0 | Ok n -> n | Error _ -> .

Inside the pattern of a drop site, the rewriter does not read the
payload of an attribute or of an extension node:

  $ mut --impl ./fixture_inner_payloads.ml | ../elide.exe
  mutation sites of "./fixture_inner_payloads.ml" in Windtrap_mut_________fixture_inner_payloads___ml:
    0: 5:15 "drop" "| Some ((x)[@note ? ((_)[@mutate off \"unread\"])]) -> ..." -> "| Some ((x)[@note ? ((_)[@mutate off \"unread\"])]) when false -> ..."
    1: 5:67 "drop" "| None -> ..." -> "| None when false -> ..."
    2: 8:15 "drop" "| [%note ? ((_)[@mutate off \"unread\"])] -> ..." -> "| [%note ? ((_)[@mutate off \"unread\"])] when false -> ..."
    3: 8:58 "drop" "| _ -> ..." -> "| _ when false -> ..."
  let attribute p =
    ((match p with
      | Some ((x)[@note ? ((_)[@mutate off "unread"])]) when
          if
            Windtrap_mut_________fixture_inner_payloads___ml.___windtrap_armed___
              0
          then false
          else true -> x
      | None when
          if
            Windtrap_mut_________fixture_inner_payloads___ml.___windtrap_armed___
              1
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
  let extension p =
    ((match p with
      | [%note ? ((_)[@mutate off "unread"])] when
          if
            Windtrap_mut_________fixture_inner_payloads___ml.___windtrap_armed___
              2
          then false
          else true -> 1
      | _ when
          if
            Windtrap_mut_________fixture_inner_payloads___ml.___windtrap_armed___
              3
          then false
          else true -> 0)
    [@ocaml.warning "-8-57"])
