(* ppxlib 0.37 encodes an effect case as an extension with this name. A
   later ppxlib keeps the extension as it is. *)
let run f =
  match f () with
  | v -> v
  | [%ppxlib.migration.ppat_effect? (Ask, k)] -> Effect.Deep.continue k 1
