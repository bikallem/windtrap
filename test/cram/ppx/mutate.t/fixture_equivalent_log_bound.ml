(* A file that declares a module [Logs] loses the rule of the logging
   call, so the arguments of [Logs.debug] keep their mutants. *)

module Logs = struct
  let debug f = f (fun _ -> ())
end

let debug x = Logs.debug (fun m -> m (x + 1))
