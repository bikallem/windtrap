(* A functor parameter named [Logs] loses the rule of the logging call for
   the file. *)

module F (Logs : S) = struct
  let debug x = Logs.debug (fun m -> m (x + 1))
end
