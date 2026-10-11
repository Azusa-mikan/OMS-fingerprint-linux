/*
 * Copyright (C) 2026 The OMS Linux driver contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * oms-ident — identify a finger against ALL templates on the chip and report
 * the matched slot. (oms-smoke's identify passes an empty gallery, which the
 * driver then excludes, so it can never match.)
 *
 * usage: oms-ident <timeout-seconds>
 */
#include "fprint.h"
#include <stdio.h>
#include <stdlib.h>

int
main (int argc, char **argv)
{
  int timeout = argc > 1 ? atoi (argv[1]) : 20;
  g_autoptr(GError) error = NULL;
  g_autoptr(FpContext) ctx = fp_context_new ();
  fp_context_enumerate (ctx);

  FpDevice *dev = NULL;
  GPtrArray *devs = fp_context_get_devices (ctx);
  for (guint i = 0; i < devs->len; i++) {
    FpDevice *d = g_ptr_array_index (devs, i);
    if (g_strcmp0 (fp_device_get_driver (d), "omsmoc") == 0) { dev = d; break; }
  }
  if (!dev) { g_printerr ("no omsmoc device\n"); return 2; }
  if (!fp_device_open_sync (dev, NULL, &error)) { g_printerr ("open: %s\n", error->message); return 3; }

  g_autoptr(GPtrArray) gallery = fp_device_list_prints_sync (dev, NULL, &error);
  if (!gallery) { g_printerr ("list: %s\n", error->message); return 4; }

  g_print ("gallery has %u print(s); press a finger (timeout %d s)...\n", gallery->len, timeout);

  FpPrint *match = NULL;
  gboolean ok = fp_device_identify_sync (dev, gallery, NULL, NULL, NULL, &match, NULL, &error);
  if (ok && match) {
    g_autofree gchar *desc = NULL, *user = NULL;
    GEnumValue *fv = NULL;
    FpFinger f;
    g_object_get (match, "description", &desc, "username", &user, "finger", &f, NULL);
    fv = g_enum_get_value (g_type_class_ref (FP_TYPE_FINGER), f);
    g_print ("MATCH: slot='%s' finger=%s user=%s\n", desc ? desc : "?", fv ? fv->value_nick : "?", user ? user : "?");
  } else {
    g_print ("NO MATCH%s%s\n", error ? ": " : "", error ? error->message : "");
  }
  fp_device_close_sync (dev, NULL, NULL);
  return 0;
}
