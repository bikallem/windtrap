(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* A stand-in for the [Logs] library, in its own file: the rewriter of
   arid.ml does not see it, and reads [Logs.debug] there by its name. *)

let logged : int Queue.t = Queue.create ()
let debug n = Queue.push n logged
