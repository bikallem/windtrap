(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The right-hand side of a [let rec] cannot be an [if] that reads a
   variable of the [let rec], so it has no [none] or [tail] guard. This
   module compiles only because the rewriter gives these values no guard: a
   [let rec] of an expression, of a class and of a functor, where the code
   does not run when the module is initialized. *)

let twos () =
  let rec twos = 2 :: twos in
  twos

class cycle =
  let rec threes = 3 :: threes in
  object
    method threes = threes
  end

type node = { next : node option }

module Make (_ : sig end) = struct
  let rec node = { next = Some node }
end

(* A [let] in the right-hand side of a [let rec] has the same restriction:
   the value of [fives] is the value of [tail], so [tail] cannot be an
   [if]. *)

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

(* A function and a [lazy] in the right-hand side run later, and keep their
   sites. *)

let sevens () =
  let rec sevens = lazy (7 :: Lazy.force sevens)
  and count n = if n = 0 then [] else n :: count (n - 1) in
  (sevens, count)
