(* The mutation rewriter over generated code. *)

(* A site at a ghost location, which is generated code, is never mutated and
   never recorded; the written [a - b] beside it is. *)
let generated a b = (a + b) [@generated]
let written a b = a - b

(* The stand-in deriver follows [copied] with a copy of it, so the copy's site
   has the line, the column and the rewrite of the first. The first site keeps
   the identifier; the copy's is neither mutated nor recorded. *)
let copied a b = a * (a + b) [@@duplicate]

(* A [drop] site has the location of the pattern of its case. The ghost
   pattern of [Some x] is generated code, so its case gets no guard; the
   written [None] beside it does. *)
let arms = function (Some x [@generated]) -> x | None -> 0

(* The copy of [picked] has the cases of the first, at the same locations, so
   its [drop] sites are neither mutated nor recorded. *)
let picked o = match o with Some x -> x | None -> 0 [@@duplicate]
