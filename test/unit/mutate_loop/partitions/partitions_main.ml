(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* Windtrap-authored runner main for two test files of one library, as the
   inline_tests backend generates it. Each `-partition` argument runs the
   tests of one file as the suite LIB/FILE. *)

module _ = Part_a
module _ = Part_b

let () = Ppx_windtrap_runtime.Ppx_runtime.init Sys.argv
let () = Ppx_windtrap_runtime.Ppx_runtime.exit ()
