(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* A suite over two instrumented files: subject.ml, and quiet.ml, whose only
   site is filtered. A scope of one file must not record the filtered
   mutant of the other, and a scope of quiet.ml has nothing to test. *)

open Windtrap

let () =
  exit
  @@ run "scoped"
       [
         test "sub of two positives" (fun () ->
             equal int 6 (Mutate_loop_subject.Subject.sub 10 4));
         test "the filtered site is run and not pinned" (fun () ->
             is_true (Mutate_loop_quiet.Quiet.same 1 <> 99));
       ]
