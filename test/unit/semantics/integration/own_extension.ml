(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* An extension constructor [()] loses [call] as a declared one does. The
   [let () = e] of this module binds the extensible type, and a [call] guard
   would give [e] the predefined [unit] in its place. *)

[@@@ocaml.warning "-65"]

type e = ..
type e += ()

let make (_ : int) : e = ()

let run x =
  let () = make x in
  1
[@@ocaml.warning "-8"]
