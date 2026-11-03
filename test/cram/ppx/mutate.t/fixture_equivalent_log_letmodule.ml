(* A [let module Logs] loses the rule of the logging call for the file. *)

let debug x =
  let module Logs = struct
    let debug f = f (fun _ -> ())
  end in
  Logs.debug (fun m -> m (x + 1))
