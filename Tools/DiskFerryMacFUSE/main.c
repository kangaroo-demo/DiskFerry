/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (c) 2026 DiskFerry contributors
 */
#include "readonly.h"
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s DISPOSABLE_NTFS_IMAGE /Volumes/MOUNT_NAME\n"
                        "Experimental read-only image transport. Requires macFUSE 5.4+ with its FSKit extension enabled.\n", argv[0]);
        return 64;
    }
    const char *target = argv[2];
    if (strncmp(target, "/Volumes/", 9) || !target[9] || strchr(target + 9, '/') ||
        !strcmp(target + 9, ".") || !strcmp(target + 9, "..")) {
        fprintf(stderr, "Use a mount directory directly under /Volumes.\n");
        return 64;
    }
    struct stat destination;
    if (lstat(target, &destination) == 0) {
        if (!S_ISDIR(destination.st_mode)) {
            fprintf(stderr, "Mount target must be a directory, without a symbolic link.\n");
            return 64;
        }
    } else if (errno != ENOENT) {
        fprintf(stderr, "Cannot inspect mount target: %s\n", strerror(errno));
        return 64;
    }
    /* macFUSE 5.4 creates a missing direct child of /Volumes for the user. */
    char error[1024] = {0};
    int rc = df_ro_open_image(argv[1], error, sizeof(error));
    if (rc) {
        fprintf(stderr, "Cannot open read-only image: %s (%s)\n", error, strerror(-rc));
        return 1;
    }
    /* No caller-supplied FUSE options: never fall back to the kernel backend. */
    char *arguments[] = { argv[0], "-f", "-s", "-o",
        "backend=fskit,ro,nosuid,nodev,noexec,fsname=DiskFerryImage,volname=DiskFerry-Test", argv[2], NULL };
    rc = fuse_main(6, arguments, df_ro_operations(), NULL);
    int closed = df_ro_close_image();
    if (closed) fprintf(stderr, "Read-only engine close failed: %s\n", strerror(-closed));
    return rc || closed ? 1 : 0;
}
