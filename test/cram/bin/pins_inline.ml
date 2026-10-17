(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The runner main of an inline-test library with two test files, as the
   inline_tests backend generates it. Each `-partition` argument runs one
   file as the suite LIB/FILE. *)

module _ = Inline_adds
module _ = Inline_subs

let () = Ppx_windtrap_runtime.Ppx_runtime.init Sys.argv
let () = Ppx_windtrap_runtime.Ppx_runtime.exit ()
