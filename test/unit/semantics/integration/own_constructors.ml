(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* A file that declares a constructor [Some], [None] or [(::)] loses [none]
   and [tail]. A [none] guard would give the predefined [None] in place of
   the [Some n] of [found], and a [tail] guard a [string] in place of a
   [pair]. This module compiles only because the rewriter gives these
   expressions no guard. The predefined constructors have the same names,
   which warning 41 reports in the source too. *)

[@@@ocaml.warning "-41"]

type found = Some of int | Missing
type pair = [] | ( :: ) of int * string

let found n = if n > 0 then Some n else Missing
let pair n s = n :: s
let size = 3
