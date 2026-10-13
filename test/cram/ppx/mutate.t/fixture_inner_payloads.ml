(* The rewriter does not read the payload of an attribute or of an extension
   node inside the pattern of a drop site. *)

let attribute p =
  match p with Some (x [@note? (_ [@mutate off "unread"])]) -> x | None -> 0

let extension p =
  match p with [%note? (_ [@mutate off "unread"])] -> 1 | _ -> 0
