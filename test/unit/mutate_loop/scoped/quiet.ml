(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Filtered: [a + 0] is [a - 0]. It is the only site of the file, so a scope
   of this file holds no mutant to test. *)
let same a = a + 0
