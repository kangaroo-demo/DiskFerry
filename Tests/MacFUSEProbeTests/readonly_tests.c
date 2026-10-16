/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (c) 2026 DiskFerry contributors
 * Tests the production FUSE callbacks on ordinary images, without mounting.
 */
#include "readonly.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct page { char names[64][1024]; off_t offset; size_t used, capacity; };
static int fill(void *context, const char *name, const struct stat *st, off_t offset) {
    (void)st;
    struct page *p = context;
    if (p->used == p->capacity) return 1;
    assert(strlen(name) < sizeof(p->names[0]));
    strcpy(p->names[p->used++], name);
    p->offset = offset;
    return 0;
}

static int contains(const struct page *p, const char *name) {
    for (size_t i = 0; i < p->used; ++i) if (!strcmp(name, p->names[i])) return 1;
    return 0;
}

static void *parallel_read(void *context) {
    const struct fuse_operations *ops = context;
    char bytes[257];
    for (int i = 0; i < 100; ++i) {
        assert(ops->read("/mixed.txt", bytes, sizeof(bytes), i, NULL) == (int)sizeof(bytes));
        for (size_t j = 0; j < sizeof(bytes); ++j) assert((unsigned char)bytes[j] == (j + i) % 251);
    }
    return NULL;
}

int main(int argc, char **argv) {
    assert(argc == 3);
    char error[1024];
    const struct fuse_operations *ops = df_ro_operations();
    struct stat st;
    assert(ops->getattr("/", &st) == -EIO);
    assert(df_ro_open_image(argv[1], error, sizeof(error)) == 0);
    assert(df_ro_open_image(argv[1], error, sizeof(error)) == -EBUSY);
    assert(ops->getattr("/", &st) == 0 && S_ISDIR(st.st_mode));
    assert((st.st_mode & 0222) == 0);
    assert(ops->getattr("/$MFT", &st) == -EPERM);
    assert(ops->getattr("/../mixed.txt", &st) == -EINVAL);
    assert(ops->getattr("//mixed.txt", &st) == -EINVAL);
    assert(ops->getattr("relative", &st) == -EINVAL);
    assert(ops->getattr("/missing", &st) == -ENOENT);
    puts("PASS lifecycle, metadata protection and invalid paths");

    assert(ops->getattr("/mixed.txt", &st) == 0 && st.st_size == 100001);
    assert(st.st_mtimespec.tv_sec == -1 && st.st_mtimespec.tv_nsec == 123456700);
    assert(st.st_birthtimespec.tv_sec == 1500000000 && st.st_birthtimespec.tv_nsec == 987654300);
    struct stat upper;
    assert(ops->getattr("/MIXED.TXT", &upper) == 0 && st.st_ino == upper.st_ino);
    struct fuse_file_info info = { .flags = O_RDONLY };
    assert(ops->open("/Mixed.txt", &info) == 0);
    char buffer[8192];
    assert(ops->read("/MiXeD.TxT", buffer, sizeof(buffer), 237, &info) == (int)sizeof(buffer));
    for (size_t i = 0; i < sizeof(buffer); ++i) assert((unsigned char)buffer[i] == (i + 237) % 251);
    assert(ops->read("/mixed.txt", buffer, 200, 99999, &info) == 2);
    assert(ops->read("/mixed.txt", buffer, sizeof(buffer), 100001, &info) == 0);
    assert(ops->read("/mixed.txt", buffer, sizeof(buffer), -1, &info) == -EINVAL);
    assert(ops->read("/", buffer, 1, 0, &info) == -EISDIR);
    puts("PASS stored-name lookup, precise negative timestamps, partial reads and EOF");

    assert(ops->read("/Caf\xc3\xa9/child", buffer, sizeof(buffer), 0, &info) == 3);
    assert(!memcmp(buffer, "NFC", 3));
    assert(ops->read("/Cafe\xcc\x81/child", buffer, sizeof(buffer), 0, &info) == 3);
    assert(!memcmp(buffer, "NFD", 3));
    assert(ops->readlink("/shortcut", buffer, sizeof(buffer)) == 0 && !strcmp(buffer, "Mixed.txt"));
    assert(ops->readlink("/mixed.txt", buffer, sizeof(buffer)) == -EINVAL);
    puts("PASS distinct Unicode paths and symbolic link target");

    struct page whole = { .capacity = 64 };
    assert(ops->readdir("/", &whole, fill, 0, NULL) == 0);
    assert(contains(&whole, ".") && contains(&whole, "..") && contains(&whole, "Mixed.txt"));
    assert(contains(&whole, "Caf\xc3\xa9") && contains(&whole, "Cafe\xcc\x81"));
    assert(!contains(&whole, "$MFT"));
    struct page first = { .capacity = 3 };
    assert(ops->readdir("/", &first, fill, 0, NULL) == 0 && first.used == 3);
    struct page second = { .capacity = 64 };
    assert(ops->readdir("/", &second, fill, first.offset, NULL) == 0);
    assert(first.used + second.used == whole.used);
    for (size_t i = 0; i < first.used; ++i) assert(!strcmp(first.names[i], whole.names[i]));
    for (size_t i = 0; i < second.used; ++i) assert(!strcmp(second.names[i], whole.names[first.used + i]));
    struct page end = { .capacity = 64 };
    assert(ops->readdir("/", &end, fill, whole.offset, NULL) == 0 && !end.used);
    assert(ops->readdir("/Mixed.txt", &end, fill, 0, NULL) == -ENOTDIR);
    assert(ops->readdir("/", &end, fill, -1, NULL) == -EINVAL);
    puts("PASS resumable directory buffers without missing or repeated names");

    assert(ops->getxattr("/mixed.txt", "user.test", NULL, 0, 0) == 5);
    assert(ops->getxattr("/mixed.txt", "user.test", buffer, 4, 0) == -ERANGE);
    assert(ops->getxattr("/mixed.txt", "user.test", buffer, 5, 0) == 5 && !memcmp(buffer, "value", 5));
    assert(ops->getxattr("/mixed.txt", "user.test", buffer, 5, 1) == -ENOTSUP);
    int names = ops->listxattr("/mixed.txt", NULL, 0);
    assert(names == 10);
    assert(ops->listxattr("/mixed.txt", buffer, 1) == -ERANGE);
    assert(ops->listxattr("/mixed.txt", buffer, sizeof(buffer)) == names && !strcmp(buffer, "user.test"));
    struct statvfs fs;
    assert(ops->statfs("/", &fs) == 0 && fs.f_blocks > 0 && (fs.f_flag & ST_RDONLY));
    assert(fs.f_bavail <= fs.f_blocks);
    puts("PASS xattr sizing and read-only space reporting");

    pthread_t readers[8];
    for (int i = 0; i < 8; ++i) assert(!pthread_create(&readers[i], NULL, parallel_read, (void *)ops));
    for (int i = 0; i < 8; ++i) assert(!pthread_join(readers[i], NULL));
    puts("PASS concurrent callbacks serialize access to the NTFS engine");

    info.flags = O_RDWR;
    assert(ops->open("/mixed.txt", &info) == 0); /* FSKit transport handle */
    assert(ops->write("/mixed.txt", "changed", 7, 0, &info) == -EROFS);
    info.flags = O_WRONLY;
    assert(ops->open("/mixed.txt", &info) == -EROFS);
    info.flags = O_RDONLY | O_TRUNC;
    assert(ops->open("/mixed.txt", &info) == -EROFS);
    assert(ops->create("/new", 0600, &info) == -EROFS);
    assert(ops->write("/mixed.txt", "changed", 7, 0, &info) == -EROFS);
    assert(ops->truncate("/mixed.txt", 0) == -EROFS);
    assert(ops->unlink("/mixed.txt") == -EROFS);
    assert(ops->rename("/mixed.txt", "/renamed") == -EROFS);
    assert(ops->mkdir("/new", 0700) == -EROFS);
    assert(ops->rmdir("/Caf\xc3\xa9") == -EROFS);
    assert(ops->symlink("Mixed.txt", "/new") == -EROFS);
    assert(ops->link("/Mixed.txt", "/new") == -EROFS);
    assert(ops->chmod("/mixed.txt", 0600) == -EROFS);
    assert(ops->chown("/mixed.txt", 0, 0) == -EROFS);
    assert(ops->utimens("/mixed.txt", NULL) == -EROFS);
    assert(ops->setxattr("/mixed.txt", "user.test", "new", 3, 0, 0) == -EROFS);
    assert(ops->removexattr("/mixed.txt", "user.test") == -EROFS);
    assert(df_ro_close_image() == 0);
    assert(ops->getattr("/mixed.txt", &st) == -EIO);
    assert(df_ro_close_image() == 0);
    puts("PASS all exposed mutations refused and closed callbacks invalidated");

    assert(df_ro_open_image("/dev/null", error, sizeof(error)) == -ENOTSUP);
    assert(df_ro_open_image(argv[2], error, sizeof(error)) == -ELOOP);
    assert(df_ro_open_image("/", error, sizeof(error)) == -ENOTSUP);
    puts("PASS device, symbolic image path and directory refused before reading");

    assert(df_ro_open_image(argv[1], error, sizeof(error)) == 0);
    struct stat source;
    assert(stat(argv[1], &source) == 0);
    struct timespec times[2] = { source.st_atimespec, source.st_mtimespec };
    times[1].tv_sec += 1;
    assert(utimensat(AT_FDCWD, argv[1], times, 0) == 0);
    assert(ops->read("/mixed.txt", buffer, sizeof(buffer), 0, NULL) == -EIO);
    assert(df_ro_close_image() == -EIO);
    puts("PASS externally changed source is refused and close retains the error");
    return 0;
}
