(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* One main with two suites over Bin_calc.Calc: the tests of pins_add.ml, then
   the tests of pins_sub.ml. The environment variable PINS_SECOND renames the
   second suite. *)

open Windtrap
module Calc = Bin_calc.Calc

let second =
  match Sys.getenv_opt "PINS_SECOND" with
  | Some name when name <> "" -> name
  | Some _ | None -> "subs"

let () =
  ignore
    (run "adds"
       [
         group "add"
           [
             test "adds two positives" (fun () -> equal int 7 (Calc.add 3 4));
             test "adds zeroes" (fun () -> equal int 0 (Calc.add 0 0));
             test "adds across zero" (fun () -> equal int 4 (Calc.add (-1) 5));
           ];
         group "sub"
           [ test "sub is nonzero" (fun () -> is_true (Calc.sub 10 4 <> 0)) ];
         group "shared"
           [
             test "shared is nonzero" (fun () -> is_true (Calc.shared 3 4 <> 0));
           ];
       ]);
  exit
  @@ run second
       [
         group "sub"
           [
             test "subtracts two positives" (fun () ->
                 equal int 6 (Calc.sub 10 4));
             test "subtracts to zero" (fun () -> equal int 0 (Calc.sub 4 4));
             test "subtracts a negative" (fun () ->
                 equal int 4 (Calc.sub (-1) (-5)));
           ];
         group "add"
           [ test "add is nonzero" (fun () -> is_true (Calc.add 3 4 <> 0)) ];
         group "shared"
           [
             test "shared is not 99" (fun () -> is_true (Calc.shared 1 2 <> 99));
           ];
       ]
