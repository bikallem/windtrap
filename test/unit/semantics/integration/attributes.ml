(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(* A warning attribute on [h :: t] covers the copy of [t] in its [tail]
   guard. This module compiles under fatal warnings only because the copy
   takes the attributes of its site. *)

let partial x y = x :: (match y with Some z -> [ z ]) [@ocaml.warning "-8"]
let listed x y = [ x; (match y with Some z -> z) ] [@ocaml.warning "-8"]
