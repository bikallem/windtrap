/*---------------------------------------------------------------------------
   Copyright (c) 2026 Invariant Systems. All rights reserved.
   SPDX-License-Identifier: ISC
  ---------------------------------------------------------------------------*/

/* A pseudo-terminal, which Unix does not open: the loop draws its live
   line only when its standard output is a terminal. The two descriptors
   close on exec. */

#define _XOPEN_SOURCE 700

#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include <caml/fail.h>

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void pty_fail (const char *what, int master)
{
  char message[256];
  int error = errno;
  if (master >= 0) close (master);
  snprintf (message, sizeof message, "openpty: %s: %s", what,
            strerror (error));
  caml_failwith (message);
}

CAMLprim value windtrap_test_openpty (value unit)
{
  CAMLparam1 (unit);
  CAMLlocal1 (pair);
  int master, slave;
  const char *name;
  master = posix_openpt (O_RDWR | O_NOCTTY);
  if (master < 0) pty_fail ("posix_openpt", -1);
  if (grantpt (master) != 0) pty_fail ("grantpt", master);
  if (unlockpt (master) != 0) pty_fail ("unlockpt", master);
  name = ptsname (master);
  if (name == NULL) pty_fail ("ptsname", master);
  slave = open (name, O_RDWR | O_NOCTTY | O_CLOEXEC);
  if (slave < 0) pty_fail ("open", master);
  if (fcntl (master, F_SETFD, FD_CLOEXEC) != 0) {
    close (slave);
    pty_fail ("fcntl", master);
  }
  pair = caml_alloc_tuple (2);
  Store_field (pair, 0, Val_int (master));
  Store_field (pair, 1, Val_int (slave));
  CAMLreturn (pair);
}
