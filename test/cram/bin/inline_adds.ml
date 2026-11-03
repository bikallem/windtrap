(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The test file that pins [Calc.add] and only reaches [Calc.sub]. *)

module Calc = Bin_calc.Calc

let%test "adds" = assert (Calc.add 3 4 = 7)
let%test "sub is nonzero" = assert (Calc.sub 10 4 <> 0)
