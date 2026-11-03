(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The test file that pins [Calc.sub] and only reaches [Calc.add]. *)

module Calc = Bin_calc.Calc

let%test "subtracts" = assert (Calc.sub 10 4 = 6)
let%test "add is nonzero" = assert (Calc.add 3 4 <> 0)
