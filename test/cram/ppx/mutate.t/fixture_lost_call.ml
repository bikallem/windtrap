(* A file that declares a constructor [()] loses [call]: its [let () = e]
   names that constructor, and a guard would give [e] the predefined
   [unit]. *)

type t = ()

let run f x =
  let () = f x in
  f x;
  x
