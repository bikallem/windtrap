(* The copy of a [tail] guard takes the attributes of its site, so that a
   warning attribute of the source covers the copy too. *)
let partial x y = ((x :: (match y with Some z -> [ z ])) [@ocaml.warning "-8"])
let listed x y = ([ x; (match y with Some z -> z) ] [@ocaml.warning "-8"])

(* A head that is a list starts at the byte of the outer site. It would have
   the identifier of that site, so it carries no [tail] site. *)
let grouped x cur acc = (x :: cur) :: acc
let single x acc = [ x ] :: acc
