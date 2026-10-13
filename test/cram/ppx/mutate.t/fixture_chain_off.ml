(* The link of a chain is no site, so [[@mutate off]] on it records nothing, and
   the [b - d] inside it is left as written. The outer [+] carries the chain's
   one mutant. *)
let link a b c d = (a + (b - d)) [@mutate off] + c

(* An inner [(::)] of a chain is no site either. [[@mutate off]] on it
   records nothing, and the [b - 1] inside it is left as written. The outer
   [(::)] carries the one [tail] mutant of the chain. *)
let cons a b t = a :: ((b - 1 :: t) [@mutate off])
