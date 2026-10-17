(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The test file that pins [Subject.widen]. Under MUTATE_WEAK its test no
   longer depends on the answer. *)

[@@@mutate exclude_file]

let weak =
  match Sys.getenv_opt "MUTATE_WEAK" with
  | Some "" | None -> false
  | Some _ -> true

let%test "pins widen" =
  let r = Mutate_loop_subject.Subject.widen 3 4 in
  assert (if weak then r <> 0 else r = 7)
