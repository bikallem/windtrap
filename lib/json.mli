(*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*)

(** JSON values and their text in UTF-8, for the machine formats of the run
    report and of the command-line tool.

    The text that each function writes is always valid JSON text.

    @canonical Windtrap.Private.Json *)

(** {1:strings Strings} *)

val string : string -> string
(** [string s] is [s] as a JSON string literal, between double quotes. It puts a
    backslash before each double quote and each backslash. It writes LF, CR and
    TAB as [\n], [\r] and [\t]. It writes each other byte below [0x20], and DEL,
    as [\u00NN] in lowercase hexadecimal. It writes each malformed UTF-8
    sequence, as [String.get_utf_8_uchar] finds it, as the UTF-8 bytes of
    U+FFFD. Every other code point passes as its UTF-8 bytes. Thus the literal
    of a string that is not valid UTF-8 does not read back as that string. *)

val add_string : Buffer.t -> string -> unit
(** [add_string b s] appends [string s] to [b]. *)

(** {1:values Values} *)

type value =
  | Int of int
  | Float of float
  | Bool of bool
  | String of string
  | List of value list
  | Object of (string * value) list  (** The fields, in this order. *)

val add : Buffer.t -> value -> unit
(** [add b v] appends [v] to [b] on one line. A comma and a space separate the
    items of a list and the fields of an object, and a colon and a space follow
    a key. A string is as {!string} writes it. A float is as [%.15g] writes it,
    or as [%.16g] or [%.17g] when fewer digits do not read back to it. A float
    that is not finite is [null]. *)
