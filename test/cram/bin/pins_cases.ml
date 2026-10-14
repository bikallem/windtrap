(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The suite over Bin_cases.Cases. Each test pins the value of one case, so
   each drop mutant is killed. *)

open Windtrap
module Cases = Bin_cases.Cases

let () =
  exit
  @@ run "pins_cases"
       [
         test "describes zero" (fun () ->
             equal string "zero" (Cases.describe 0));
         test "describes one" (fun () ->
             equal string
               "one, which is the first of the positive numbers and the \
                smallest of them all"
               (Cases.describe 1));
         test "describes many" (fun () ->
             equal string "many" (Cases.describe 2));
       ]
