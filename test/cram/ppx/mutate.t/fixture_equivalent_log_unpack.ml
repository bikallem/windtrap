(* A first-class module unpacked as [Logs] loses the rule of the logging
   call for the file. *)

let debug (module Logs : S) x = Logs.debug (fun m -> m (x + 1))
