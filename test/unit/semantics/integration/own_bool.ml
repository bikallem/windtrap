(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* An extension constructor [true] or [false] loses [arm] as a declared one
   does. The guard of a case names [true] and [false] where [bool] is
   expected, and under fatal warnings warning 42 then stops the build. *)

type e = ..
type e += false | true

let size n = match n with 0 -> "none" | _ -> "some"
