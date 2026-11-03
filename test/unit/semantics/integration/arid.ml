(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* One site of each rule of equivalence. An arid site has no record and no
   guard. In [chain], [a + b] keeps its mutant. The rule of a logging call
   reads the name of the function as the source spells it, so a local
   [Logs] module shows it, and its queue shows that the argument is
   unchanged. *)

let zero x = x + 0
let chain a b = a + b + 0
let same a = a && a
let branches c x = if c then x else x
let message n = if n < 0 then invalid_arg (string_of_int 3) else n

module Logs = struct
  let logged = Queue.create ()
  let debug n = Queue.push n logged
end

let logged x = Logs.debug (x + x)
