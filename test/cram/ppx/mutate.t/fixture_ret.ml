(* [ret] gives [None] in place of [Some e], under [none], and [t] in place
   of [h :: t], under [tail]. The armed arm of [tail] is a copy of [t] with
   no guard. A list literal is one site, at its bracket. *)

let wrap x = Some (x + 1)
let push x xs = x :: xs
let three = [ 1; 2; 3 ]
let pair x y = x :: [ y ]

(* In a chain of [(::)], the outermost [(::)] alone is a site. *)
let chain a b t = a :: b :: t

(* The right-hand side of a [let rec] has no [ret] site, except in its
   functions and its [lazy] bodies. This is also true in a class. *)
let rec ones = 1 :: ones
let rec stream = lazy (1 :: Lazy.force stream)
let rec count n = if n = 0 then [] else n :: count (n - 1)

class cycle =
  let rec ones = 1 :: ones in
  object
    method ones = ones
  end

(* A qualified constructor, [None] and [[]] are no sites. *)
let qualified x = Option.Some x
let empty = (None, [])
