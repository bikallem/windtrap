(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* A file that declares a constructor [()] loses [call]. Its [let () = e]
   binds the type of the file, and a [call] guard would give [e] the
   predefined [unit] in its place. This module compiles only because the
   rewriter gives that binding no guard. *)

[@@@ocaml.warning "-65"]

type t = ()

let run (f : int -> t) x =
  let () = f x in
  x
