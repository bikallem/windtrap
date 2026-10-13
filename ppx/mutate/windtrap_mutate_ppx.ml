(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* The driver parses its command line before it rewrites a file, so the
   flags are read when [transform_impl_file] runs. *)
let arm = ref true
let call = ref true
let lit = ref false
let ret = ref true

let () =
  Ppxlib.Driver.add_arg "-no-arm" (Arg.Clear arm)
    ~doc:" Do not drop the cases of a match (the arm mutants).";
  Ppxlib.Driver.add_arg "-no-call" (Arg.Clear call)
    ~doc:" Do not skip the calls whose value is discarded (the call mutants).";
  Ppxlib.Driver.add_arg "-lit" (Arg.Set lit)
    ~doc:" Change the integer, float and boolean literals (the lit mutants).";
  Ppxlib.Driver.add_arg "-no-ret" (Arg.Clear ret)
    ~doc:" Do not replace Some e with None and h :: t with t (the ret mutants).";
  let instrument =
    Ppxlib.Driver.Instrument.V2.make
      (fun ctxt ast ->
        Instrument.transform_impl_file ~arm:!arm ~call:!call ~lit:!lit ~ret:!ret
          ctxt ast)
      ~position:After
  in
  Ppxlib.Driver.register_transformation ~instrument "windtrap_mutate"
