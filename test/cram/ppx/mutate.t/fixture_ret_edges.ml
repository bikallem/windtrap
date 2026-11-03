(* The copy of a [tail] guard takes the attributes of its site, so that a
   warning attribute of the source covers the copy too. *)
let partial x y = ((x :: (match y with Some z -> [ z ])) [@ocaml.warning "-8"])
let listed x y = ([ x; (match y with Some z -> z) ] [@ocaml.warning "-8"])

(* When the head of a site written as [h :: t] is a list, it starts at the
   first byte of the site. It would have the identifier of the site, so it
   has no [tail] site of its own. A list head in a list literal or in the
   middle of a chain keeps its own site. *)
let grouped x cur acc = (x :: cur) :: acc
let single x acc = [ x ] :: acc
let middle x y acc = y :: [ x ] :: acc
let nested x y = [ [ x ]; [ y ] ]
