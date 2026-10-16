/* SPDX-License-Identifier: GPL-2.0-only
 * Copyright (c) 2026 DiskFerry contributors
 *
 * Experimental macFUSE transport for the existing callback NTFS engine.
 * Only ordinary images, opened O_RDONLY, are accepted. System FSKit mounting
 * is a separate qualification step; these callbacks do not enable writing.
 */
#include "readonly.h"
#include "ntfs_bridge.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

static pthread_mutex_t engine_lock = PTHREAD_MUTEX_INITIALIZER;
static nk_volume *volume;
static int image_fd = -1;
static struct stat image_identity;

static int failure(void) { return -(errno ? errno : EIO); }

static long long image_read(void *context, void *buffer, long long count, long long offset) {
    (void)context;
    struct stat current;
    if (count < 0 || count > 16 * 1024 * 1024 || offset < 0 ||
        offset > image_identity.st_size || count > image_identity.st_size - offset ||
        fstat(image_fd, &current) || current.st_dev != image_identity.st_dev ||
        current.st_ino != image_identity.st_ino || current.st_size != image_identity.st_size ||
        current.st_mtimespec.tv_sec != image_identity.st_mtimespec.tv_sec ||
        current.st_mtimespec.tv_nsec != image_identity.st_mtimespec.tv_nsec ||
        current.st_ctimespec.tv_sec != image_identity.st_ctimespec.tv_sec ||
        current.st_ctimespec.tv_nsec != image_identity.st_ctimespec.tv_nsec) {
        errno = EIO;
        return -1;
    }
    ssize_t result;
    do { result = pread(image_fd, buffer, (size_t)count, (off_t)offset); }
    while (result < 0 && errno == EINTR);
    return result;
}

int df_ro_open_image(const char *path, char *error, size_t capacity) {
    pthread_mutex_lock(&engine_lock);
    if (error && capacity) error[0] = '\0';
    int result = 0;
    struct stat before;
    if (volume || image_fd != -1) { errno = EBUSY; goto failed; }
    if (!path) { errno = EINVAL; goto failed; }
    if (lstat(path, &before)) goto failed;
    if (S_ISLNK(before.st_mode)) { errno = ELOOP; goto failed; }
    if (!S_ISREG(before.st_mode)) { errno = ENOTSUP; goto failed; }
    image_fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (image_fd == -1) goto failed;
    if (fstat(image_fd, &image_identity)) goto failed_open;
    if (!S_ISREG(image_identity.st_mode) || before.st_dev != image_identity.st_dev ||
        before.st_ino != image_identity.st_ino) { errno = ESTALE; goto failed_open; }
    if (flock(image_fd, LOCK_SH | LOCK_NB)) goto failed_open;
    nk_io io = { .pread = image_read, .size = image_identity.st_size, .readonly = 1 };
    volume = nk_mount_io(&io, error, capacity);
    if (!volume) goto failed_open;
    goto done;
failed_open: {
    int saved = errno ? errno : EIO;
    close(image_fd);
    image_fd = -1;
    errno = saved;
}
failed:
    result = failure();
    if (error && capacity && !error[0]) snprintf(error, capacity, "%s", strerror(-result));
done:
    pthread_mutex_unlock(&engine_lock);
    return result;
}

int df_ro_close_image(void) {
    pthread_mutex_lock(&engine_lock);
    int result = volume && nk_umount(volume) ? failure() : 0;
    volume = NULL;
    if (image_fd != -1 && close(image_fd) && !result) result = failure();
    image_fd = -1;
    pthread_mutex_unlock(&engine_lock);
    return result;
}

/* Use the bridge's stored-name lookup rather than POSIX/Unicode folding. */
static int resolve(const char *path, char **actual, nk_stat *attributes) {
    if (!volume) return -EIO;
    if (!path || path[0] != '/') return -EINVAL;
    size_t length = strlen(path);
    if (length > 32768) return -ENAMETOOLONG;
    char *result = calloc(32769, 1);
    char *components = strdup(path + 1);
    if (!result || !components) { free(result); free(components); return -ENOMEM; }
    strcpy(result, "/");
    int rc = 0;
    if (!components[0]) {
        if (nk_stat_path(volume, "/", attributes)) rc = failure();
    } else {
        char *next = components, *part;
        while ((part = strsep(&next, "/"))) {
            if (!part[0] || !strcmp(part, ".") || !strcmp(part, "..")) { rc = -EINVAL; break; }
            char name[1024];
            if (nk_lookup_child(volume, result, part, name, sizeof(name), attributes)) {
                rc = failure(); break;
            }
            size_t used = strlen(result), added = strlen(name), slash = used > 1;
            if (used + added + slash > 32768) { rc = -ENAMETOOLONG; break; }
            if (slash) result[used++] = '/';
            memcpy(result + used, name, added + 1);
        }
    }
    free(components);
    if (rc) free(result); else *actual = result;
    return rc;
}

static int ro_getattr(const char *path, struct stat *out) {
    pthread_mutex_lock(&engine_lock);
    char *actual = NULL;
    nk_stat st;
    int rc = resolve(path, &actual, &st);
    if (!rc) {
        memset(out, 0, sizeof(*out));
        out->st_mode = st.is_symlink ? (S_IFLNK | 0777) : st.is_dir ? (S_IFDIR | 0555) : (S_IFREG | 0444);
        out->st_ino = st.inode;
        out->st_nlink = st.is_dir ? 2 : 1;
        out->st_uid = getuid(); out->st_gid = getgid();
        out->st_size = st.size;
        out->st_blocks = st.alloc_size / 512 + (st.alloc_size % 512 != 0);
        out->st_blksize = 4096;
        out->st_atimespec = (struct timespec){ st.atime, st.atime_nsec };
        out->st_mtimespec = (struct timespec){ st.mtime, st.mtime_nsec };
        out->st_ctimespec = (struct timespec){ st.ctime, st.ctime_nsec };
        out->st_birthtimespec = (struct timespec){ st.btime, st.btime_nsec };
    }
    free(actual);
    pthread_mutex_unlock(&engine_lock);
    return rc;
}

static int ro_open(const char *path, struct fuse_file_info *info) {
    /* macFUSE documents FSKit opening handles as O_RDWR even on read paths.
     * Accept that transport handle, while the mount, source fd and every
     * mutation callback remain read-only. Never accept creation/truncation. */
    int access = info->flags & O_ACCMODE;
    if ((access != O_RDONLY && access != O_RDWR) || (info->flags & (O_TRUNC | O_CREAT | O_APPEND))) return -EROFS;
    struct stat st;
    int rc = ro_getattr(path, &st);
    return rc ? rc : S_ISDIR(st.st_mode) ? -EISDIR : S_ISLNK(st.st_mode) ? -ELOOP : 0;
}

static int ro_read(const char *path, char *buffer, size_t size, off_t offset, struct fuse_file_info *info) {
    (void)info;
    if (offset < 0 || size > INT_MAX) return -EINVAL;
    pthread_mutex_lock(&engine_lock);
    char *actual = NULL;
    nk_stat st;
    int rc = resolve(path, &actual, &st);
    if (!rc && (st.is_dir || st.is_symlink)) rc = st.is_dir ? -EISDIR : -ELOOP;
    if (!rc) {
        long long count = nk_read(volume, actual, offset, (long long)size, buffer);
        rc = count < 0 ? failure() : (int)count;
    }
    free(actual);
    pthread_mutex_unlock(&engine_lock);
    return rc;
}

static int ro_readlink(const char *path, char *buffer, size_t size) {
    pthread_mutex_lock(&engine_lock);
    char *actual = NULL;
    nk_stat st;
    int rc = resolve(path, &actual, &st);
    if (!rc && !st.is_symlink) rc = -EINVAL;
    if (!rc && nk_readlink(volume, actual, buffer, size)) rc = failure();
    free(actual);
    pthread_mutex_unlock(&engine_lock);
    return rc;
}

struct directory_reply {
    void *buffer;
    fuse_fill_dir_t fill;
    off_t index, requested;
};

static int add_entry(struct directory_reply *reply, const char *name) {
    off_t next = reply->index + 1;
    if (reply->index >= reply->requested && reply->fill(reply->buffer, name, NULL, next)) return 1;
    reply->index = next;
    return 0;
}

static int list_entry(void *context, const nk_dirent *entry) {
    return add_entry(context, entry->name);
}

static int ro_readdir(const char *path, void *buffer, fuse_fill_dir_t fill, off_t offset, struct fuse_file_info *info) {
    (void)info;
    if (offset < 0) return -EINVAL;
    pthread_mutex_lock(&engine_lock);
    char *actual = NULL;
    nk_stat st;
    int rc = resolve(path, &actual, &st);
    if (!rc && !st.is_dir) rc = -ENOTDIR;
    if (!rc) {
        struct directory_reply reply = { .buffer = buffer, .fill = fill, .requested = offset };
        if (!add_entry(&reply, ".") && !add_entry(&reply, "..") && nk_list(volume, actual, list_entry, &reply)) rc = failure();
    }
    free(actual);
    pthread_mutex_unlock(&engine_lock);
    return rc;
}

static int ro_statfs(const char *path, struct statvfs *out) {
    (void)path;
    pthread_mutex_lock(&engine_lock);
    long long total, available;
    int cluster;
    int rc = !volume ? -EIO : nk_statvfs(volume, &total, &available, &cluster) ? failure() : 0;
    if (!rc && (cluster <= 0 || total < 0 || available < 0 || available > total)) rc = -EIO;
    if (!rc) {
        memset(out, 0, sizeof(*out));
        out->f_bsize = out->f_frsize = (unsigned long)cluster;
        out->f_blocks = (fsblkcnt_t)(total / cluster);
        out->f_bfree = out->f_bavail = (fsblkcnt_t)(available / cluster);
        out->f_namemax = 255;
        out->f_flag = ST_RDONLY | ST_NOSUID;
    }
    pthread_mutex_unlock(&engine_lock);
    return rc;
}

static int ro_getxattr(const char *path, const char *name, char *buffer, size_t size, uint32_t position) {
    if (position) return -ENOTSUP;
    if (size > INT_MAX) return -E2BIG;
    pthread_mutex_lock(&engine_lock);
    char *actual = NULL;
    nk_stat st;
    int rc = resolve(path, &actual, &st);
    if (!rc) {
        long long count = nk_xattr_get(volume, actual, name, size ? buffer : NULL, (long long)size);
        rc = count < 0 ? failure() : count > INT_MAX ? -EOVERFLOW : (int)count;
    }
    free(actual);
    pthread_mutex_unlock(&engine_lock);
    return rc;
}

struct xattr_reply { char *buffer; size_t size, used; int error; };

static int list_attribute(void *context, const char *name) {
    struct xattr_reply *reply = context;
    size_t bytes = strlen(name) + 1;
    if (bytes > INT_MAX - reply->used) { reply->error = -EOVERFLOW; return 1; }
    if (reply->buffer) {
        if (bytes > reply->size - reply->used) { reply->error = -ERANGE; return 1; }
        memcpy(reply->buffer + reply->used, name, bytes);
    }
    reply->used += bytes;
    return 0;
}

static int ro_listxattr(const char *path, char *buffer, size_t size) {
    pthread_mutex_lock(&engine_lock);
    char *actual = NULL;
    nk_stat st;
    int rc = resolve(path, &actual, &st);
    struct xattr_reply reply = { .buffer = size ? buffer : NULL, .size = size };
    if (!rc && nk_xattr_list(volume, actual, list_attribute, &reply)) rc = failure();
    if (!rc) rc = reply.error ? reply.error : (int)reply.used;
    free(actual);
    pthread_mutex_unlock(&engine_lock);
    return rc;
}

/* Explicit refusal also covers requests received despite a read-only mount. */
static int ro_path(const char *p) { (void)p; return -EROFS; }
static int ro_pair(const char *a, const char *b) { (void)a; (void)b; return -EROFS; }
static int ro_mode(const char *p, mode_t m) { (void)p; (void)m; return -EROFS; }
static int ro_mknod(const char *p, mode_t m, dev_t d) { (void)p; (void)m; (void)d; return -EROFS; }
static int ro_chown(const char *p, uid_t u, gid_t g) { (void)p; (void)u; (void)g; return -EROFS; }
static int ro_truncate(const char *p, off_t n) { (void)p; (void)n; return -EROFS; }
static int ro_create(const char *p, mode_t m, struct fuse_file_info *f) { (void)p; (void)m; (void)f; return -EROFS; }
static int ro_write(const char *p, const char *b, size_t n, off_t o, struct fuse_file_info *f) {
    (void)p; (void)b; (void)n; (void)o; (void)f; return -EROFS;
}
static int ro_utimens(const char *p, const struct timespec t[2]) { (void)p; (void)t; return -EROFS; }
static int ro_setxattr(const char *p, const char *n, const char *b, size_t s, int f, uint32_t o) {
    (void)p; (void)n; (void)b; (void)s; (void)f; (void)o; return -EROFS;
}

const struct fuse_operations *df_ro_operations(void) {
    static const struct fuse_operations operations = {
        .getattr = ro_getattr, .readlink = ro_readlink, .open = ro_open, .read = ro_read,
        .readdir = ro_readdir, .statfs = ro_statfs, .getxattr = ro_getxattr, .listxattr = ro_listxattr,
        .mknod = ro_mknod, .mkdir = ro_mode, .unlink = ro_path, .rmdir = ro_path,
        .symlink = ro_pair, .rename = ro_pair, .link = ro_pair, .chmod = ro_mode,
        .chown = ro_chown, .truncate = ro_truncate, .create = ro_create, .write = ro_write,
        .utimens = ro_utimens, .setxattr = ro_setxattr, .removexattr = ro_pair,
    };
    return &operations;
}
