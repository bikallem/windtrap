(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* One site of each filter: a filtered site carries no guard, so arming it
   changes nothing. In [chain], [a + b] keeps its mutant. The library gives
   [-log-function Log.debug], and [Log.debug] keeps its argument, so that a
   guard in the argument changes a reading. *)

let zero x = x + 0
let chain a b = a + b + 0
let same a = a && a
let branches c x = if c then x else x
let cases = function `A -> 0 | _ -> 0
let message n = if n < 0 then invalid_arg (string_of_int 3) else n

module Log = struct
  let logged = Queue.create ()
  let debug n = Queue.push n logged
end

let logged x = Log.debug (x + x)
