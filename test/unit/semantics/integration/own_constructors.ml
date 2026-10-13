(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* A file that declares a constructor [Some], [None] or [(::)] loses [ret],
   and one that declares [true] or [false] loses the [flip] rewrite of [lit].
   A [none] guard would give [None] of the predefined option in place of
   [Some n] of [found], a [tail] guard a [string] in place of a [pair], and a
   [flip] guard the predefined [false] in place of a [truth]. This module
   compiles only because the rewriter gives these expressions no guard. Its
   integer literals keep their [lit] mutants. The predefined constructors
   have the same names, which warning 41 reports in the source too. *)

[@@@ocaml.warning "-41"]

type found = Some of int | Missing
type pair = [] | ( :: ) of int * string
type truth = true | Unknown

let found n = if n > 0 then Some n else Missing
let pair n s = n :: s
let sure : truth = true
let unsure : truth = Unknown
let size = 3
