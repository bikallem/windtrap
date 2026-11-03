(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* An [open!] brings the [None] of Levels into scope. The [None] of a [none]
   guard gets the type of [Some x] by type-directed disambiguation, which the
   source does not do. This module compiles under fatal warnings and
   [-principal] only because the guard turns off the warnings of
   disambiguation. *)

open! Levels

let wrap x = Some x
let low = Low
