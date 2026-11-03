(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* One site of each arid rule of this pass. An arid site has no record and
   no guard. In [chain], [a + b] keeps its mutant. [Logs] is logs.ml of this
   library, which the rewriter of this file does not see. Its queue shows
   that the argument is unchanged. *)

let zero x = x + 0
let chain a b = a + b + 0
let same a = a && a
let branches c x = if c then x else x
let message n = if n < 0 then invalid_arg (string_of_int 3) else n
let logged x = Logs.debug (x + x)
