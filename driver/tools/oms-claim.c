/*
 * Copyright (C) 2026 The OMS Linux driver contributors
 * SPDX-License-Identifier: LGPL-2.1-or-later
 *
 * oms-claim — map existing OMS chip templates into fprintd's storage.
 *
 * The chip holds match-on-chip templates in 16 slots. fprintd only "owns"
 * a finger if it has a print file under
 *   /var/lib/fprint/<user>/omsmoc/<device-id>/<finger-number>
 * whose fpi-data holds the chip slot. This tool lists the templates that
 * already exist on the chip (via the driver) and writes fprintd print files
 * for chosen slot -> finger mappings, so pre-existing templates become usable
 * without re-enrolling (the chip rejects duplicate enrollments).
 *
 * Must be run as root (fprintd storage is root-only).
 *
 * usage: oms-claim <username> <slot>:<finger> [<slot>:<finger> ...]
 *   e.g. oms-claim alice 2:right-index-finger 2:right-middle-finger
 */

#include "fprint.h"

#include <glib.h>
#include <glib/gstdio.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static const struct { const char *name; FpFinger finger; } FINGERS[] = {
  { "left-thumb", FP_FINGER_LEFT_THUMB }, { "left-index-finger", FP_FINGER_LEFT_INDEX },
  { "left-middle-finger", FP_FINGER_LEFT_MIDDLE }, { "left-ring-finger", FP_FINGER_LEFT_RING },
  { "left-little-finger", FP_FINGER_LEFT_LITTLE }, { "right-thumb", FP_FINGER_RIGHT_THUMB },
  { "right-index-finger", FP_FINGER_RIGHT_INDEX }, { "right-middle-finger", FP_FINGER_RIGHT_MIDDLE },
  { "right-ring-finger", FP_FINGER_RIGHT_RING }, { "right-little-finger", FP_FINGER_RIGHT_LITTLE },
};

static gboolean
parse_finger (const char *s, FpFinger *out)
{
  for (guint i = 0; i < G_N_ELEMENTS (FINGERS); i++)
    if (g_strcmp0 (s, FINGERS[i].name) == 0) { *out = FINGERS[i].finger; return TRUE; }
  return FALSE;
}

/* Slot number from a print's description ("Slot N") */
static gboolean
slot_of (FpPrint *p, guint *slot)
{
  g_autofree gchar *desc = NULL;
  g_object_get (p, "description", &desc, NULL);
  if (!desc || sscanf (desc, "Slot %u", slot) != 1)
    return FALSE;
  return TRUE;
}

int
main (int argc, char **argv)
{
  if (argc < 3) {
    g_printerr ("usage: %s <username> <slot>:<finger> [...]\n  e.g. %s alice 2:right-index-finger 2:right-middle-finger\n",
                argv[0], argv[0]);
    return 1;
  }
  const char *username = argv[1];

  /* parse requested slot->finger mappings */
  GHashTable *want = g_hash_table_new (g_direct_hash, g_direct_equal);
  for (int i = 2; i < argc; i++) {
    char **parts = g_strsplit (argv[i], ":", 2);
    FpFinger finger;
    if (!parts[0] || !parts[1] || !parse_finger (parts[1], &finger)) {
      g_printerr ("bad mapping '%s'\n", argv[i]);
      g_strfreev (parts);
      return 1;
    }
    g_hash_table_insert (want, GUINT_TO_POINTER (atoi (parts[0])), GUINT_TO_POINTER (finger));
    g_strfreev (parts);
  }

  g_autoptr(GError) error = NULL;
  g_autoptr(FpContext) ctx = fp_context_new ();
  fp_context_enumerate (ctx);

  FpDevice *dev = NULL;
  GPtrArray *devs = fp_context_get_devices (ctx);
  for (guint i = 0; i < devs->len; i++) {
    FpDevice *d = g_ptr_array_index (devs, i);
    if (g_strcmp0 (fp_device_get_driver (d), "omsmoc") == 0) { dev = d; break; }
  }
  if (!dev) { g_printerr ("no omsmoc device found\n"); return 2; }

  const char *device_id = fp_device_get_device_id (dev);
  g_print ("device: %s (%s)\n", fp_device_get_name (dev), device_id);

  if (!fp_device_open_sync (dev, NULL, &error)) {
    g_printerr ("open failed: %s\n", error->message);
    return 3;
  }

  g_autoptr(GPtrArray) prints = fp_device_list_prints_sync (dev, NULL, &error);
  if (!prints) {
    g_printerr ("list_prints failed: %s\n", error->message);
    return 4;
  }

  g_autofree gchar *dir = g_strdup_printf ("/var/lib/fprint/%s/omsmoc/%s", username, device_id);
  if (g_mkdir_with_parents (dir, 0700) != 0) {
    g_printerr ("cannot create %s (run as root?)\n", dir);
    return 5;
  }

  int written = 0;
  for (guint i = 0; i < prints->len; i++) {
    FpPrint *p = g_ptr_array_index (prints, i);
    guint slot;
    if (!slot_of (p, &slot)) continue;
    gpointer fv = g_hash_table_lookup (want, GUINT_TO_POINTER (slot));
    if (!fv) continue;
    FpFinger finger = (FpFinger) GPOINTER_TO_UINT (fv);

    GDate *date = g_date_new ();
    g_date_set_time_t (date, time (NULL));
    g_object_set (p,
                  "finger", finger,
                  "username", username,
                  "enroll-date", date,
                  NULL);
    g_date_free (date);

    guchar *data = NULL;
    gsize len = 0;
    if (!fp_print_serialize (p, &data, &len, &error)) {
      g_printerr ("serialize slot %u failed: %s\n", slot, error->message);
      continue;
    }
    g_autofree gchar *path = g_strdup_printf ("%s/%d", dir, (int) finger);
    if (g_file_set_contents (path, (const char *) data, len, &error)) {
      g_print ("slot %u -> finger %d  =>  %s (%zu bytes)\n", slot, (int) finger, path, len);
      written++;
    } else {
      g_printerr ("write %s failed: %s\n", path, error->message);
    }
    g_free (data);
  }

  fp_device_close_sync (dev, NULL, NULL);
  g_print ("done, %d print file(s) written\n", written);
  return written > 0 ? 0 : 6;
}
