(* A module [Logs] in a signature loses the rule of the logging call for
   the file. *)

module type S = sig
  module Logs : sig
    val debug : ((int -> unit) -> unit) -> unit
  end
end

let debug x = Logs.debug (fun m -> m (x + 1))
