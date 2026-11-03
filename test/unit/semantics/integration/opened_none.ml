(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* An [open] brings the [None] of Codec into scope, which the rewriter does
   not see. The [None] of a [none] guard comes after [Some x], so it takes
   the type of the predefined option, and this module compiles. *)

open Codec

let wrap x = Some x
let default = Gzip
