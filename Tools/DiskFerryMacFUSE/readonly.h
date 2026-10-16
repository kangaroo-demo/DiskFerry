/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (c) 2026 DiskFerry contributors
 */
#ifndef DISKFERRY_FUSE_READONLY_H
#define DISKFERRY_FUSE_READONLY_H
#define FUSE_USE_VERSION 26
#include <fuse.h>

/* One read-only, ordinary NTFS image per process. No device access or writes. */
int df_ro_open_image(const char *path, char *error, size_t capacity);
int df_ro_close_image(void);
const struct fuse_operations *df_ro_operations(void);

#endif
