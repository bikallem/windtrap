(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The library of since.t for drop mutants. Its only mutants are the drop
   mutants of the three cases. The body of the second case is on the line
   after its pattern, and the identifier of its drop mutant has the line of
   the pattern. *)

let describe n =
  match n with
  | 0 -> "zero"
  | 1 ->
      "one, which is the first of the positive numbers and the smallest of \
       them all"
  | _ -> "many"
