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
let filter = ref true
let log_functions = ref []

let () =
  Ppxlib.Driver.add_arg "-no-arm" (Arg.Clear arm)
    ~doc:" Do not drop the cases of a match (the arm mutants).";
  Ppxlib.Driver.add_arg "-no-call" (Arg.Clear call)
    ~doc:" Do not skip the calls whose value is discarded (the call mutants).";
  Ppxlib.Driver.add_arg "-lit" (Arg.Set lit)
    ~doc:" Change the integer, float and boolean literals (the lit mutants).";
  Ppxlib.Driver.add_arg "-no-ret" (Arg.Clear ret)
    ~doc:" Do not replace Some e with None and h :: t with t (the ret mutants).";
  Ppxlib.Driver.add_arg "-no-filter" (Arg.Clear filter)
    ~doc:" Test every mutant, and record none as filtered.";
  Ppxlib.Driver.add_arg "-log-function"
    (Arg.String (fun name -> log_functions := name :: !log_functions))
    ~doc:
      "NAME Filter the mutants in the arguments of the logging function NAME, \
       as Log.debug.";
  let instrument =
    Ppxlib.Driver.Instrument.V2.make
      (fun ctxt ast ->
        Instrument.transform_impl_file ~arm:!arm ~call:!call ~lit:!lit ~ret:!ret
          ~filter:!filter ~log_functions:(List.rev !log_functions) ctxt ast)
      ~position:After
  in
  Ppxlib.Driver.register_transformation ~instrument "windtrap_mutate"
