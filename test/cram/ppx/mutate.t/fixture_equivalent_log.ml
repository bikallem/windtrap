(* [logging call]: every site in the arguments of a function of [Logs]
   that logs a message is filtered, as [x + 1] and [Some x]. A printing
   function writes what an expect test reads, so its arguments keep their
   mutants, and so does the call itself. A statement in the arguments acts
   on the state of the program, so it keeps its mutants. [-log-function]
   adds names. *)

let debug x = Logs.debug (fun m -> m "%d %a" (x + 1) Fmt.(option int) (Some x))
let info x = Logs.info @@ fun m -> m "%d" (x - 1)
let print x = Printf.printf "%d" (x + 1)

let local x =
  Log.debug (fun m -> m "%d" (x + 1));
  x

let app x = Logs.app (fun m -> m "%d" (x + 1))
let err x = Logs.err (fun m -> m "%d" (x + 1))
let warn x = Logs.warn (fun m -> m "%d" (x + 1))
let msg x = Logs.msg Logs.Info (fun m -> m "%d" (x + 1))

let counted y x =
  Logs.debug (fun m ->
      y := !y + 1;
      let () = incr y in
      m "%d" !y);
  !y + x
