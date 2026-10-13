(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The right-hand side of a [let rec] cannot be an [if] that reads a
   variable of the [let rec], so it has no [ret] guard. This module compiles
   only because the rewriter gives these values no guard: a [let rec] of a
   structure, of an expression and of a class. *)

let rec ones = 1 :: ones

let twos () =
  let rec twos = 2 :: twos in
  twos

class cycle =
  let rec threes = 3 :: threes in
  object
    method threes = threes
  end

(* A [let] in the right-hand side of a [let rec] has the same restriction:
   the value of [fours] is the value of [tail], so [tail] cannot be an
   [if]. *)

let rec fours =
  let tail = 4 :: fours in
  tail

let fives () =
  let rec fives =
    let tail = 5 :: fives in
    tail
  in
  fives

class cycles =
  let rec sixes =
    let tail = 6 :: sixes in
    tail
  in
  object
    method sixes = sixes
  end
