/* SPDX-License-Identifier: GPL-2.0-or-later
 * Derived from NTFSKit commit 96ecccb1, DNA MAKER COMPANY LIMITED and contributors.
 * Modified for DiskFerry 2026-10-16; see ../UPSTREAM.md.
 */
#include "ntfs_bridge.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include <ntfs-3g/types.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/ntfstime.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/reparse.h>
#include <ntfs-3g/runlist.h>
#include <ntfs-3g/logging.h>

struct nk_volume {
    ntfs_volume *vol;
    void *devctx;        /* nk_devctx when mounted via nk_mount_io */

};

static int require_writable(nk_volume *v) {
    if (!v || !v->vol) { errno = EINVAL; return -1; }
    if (NVolReadOnly(v->vol)) { errno = EROFS; return -1; }
    return 0;
}

static u64 nk_mref(ntfs_inode *ni) {
    return MK_MREF(ni->mft_no, le16_to_cpu(ni->mrec->sequence_number));
}

/* ---- callback-backed ntfs_device ---- */

struct nk_devctx {
    nk_io io;
    s64   pos;
};

static int nkdev_open(struct ntfs_device *dev, int flags) {
    if ((flags & O_ACCMODE) == O_RDONLY)
        NDevSetReadOnly(dev);
    NDevSetOpen(dev);
    return 0;
}

static int nkdev_close(struct ntfs_device *dev) {
    NDevClearOpen(dev);
    return 0;
}

static s64 nkdev_seek(struct ntfs_device *dev, s64 offset, int whence) {
    struct nk_devctx *c = dev->d_private;
    s64 base = whence == SEEK_SET ? 0 :
               whence == SEEK_CUR ? c->pos : c->io.size;
    if ((whence != SEEK_SET && whence != SEEK_CUR && whence != SEEK_END) ||
        (offset > 0 && base > INT64_MAX - offset) ||
        (offset < 0 && offset < -base) || base + offset > c->io.size) {
        errno = EINVAL; return -1;
    }
    c->pos = base + offset;
    return c->pos;
}

static s64 nkdev_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset) {
    struct nk_devctx *c = dev->d_private;
    if (count < 0 || offset < 0 || offset > c->io.size || count > c->io.size - offset) {
        errno = EINVAL; return -1;
    }
    s64 n = c->io.pread(c->io.ctx, buf, count, offset);
    if (n > count) { errno = EIO; return -1; }
    if (n < 0) { errno = EIO; return -1; }
    return n;
}

static s64 nkdev_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset) {
    struct nk_devctx *c = dev->d_private;
    if (NDevReadOnly(dev)) { errno = EROFS; return -1; }
    if (count < 0 || offset < 0 || offset > c->io.size || count > c->io.size - offset) {
        errno = EINVAL; return -1;
    }
    s64 n = c->io.pwrite(c->io.ctx, buf, count, offset);
    if (n > count) { errno = EIO; return -1; }
    if (n < 0) { errno = EIO; return -1; }
    NDevSetDirty(dev);
    return n;
}

static s64 nkdev_read(struct ntfs_device *dev, void *buf, s64 count) {
    struct nk_devctx *c = dev->d_private;
    s64 n = nkdev_pread(dev, buf, count, c->pos);
    if (n > 0) c->pos += n;
    return n;
}

static s64 nkdev_write(struct ntfs_device *dev, const void *buf, s64 count) {
    struct nk_devctx *c = dev->d_private;
    s64 n = nkdev_pwrite(dev, buf, count, c->pos);
    if (n > 0) c->pos += n;
    return n;
}

static int nkdev_sync(struct ntfs_device *dev) {
    struct nk_devctx *c = dev->d_private;
    if (!NDevReadOnly(dev) && (!c->io.sync || c->io.sync(c->io.ctx))) {
        errno = EIO; return -1;
    }
    NDevClearDirty(dev);
    return 0;
}

static int nkdev_stat(struct ntfs_device *dev, struct stat *buf) {
    struct nk_devctx *c = dev->d_private;
    memset(buf, 0, sizeof(*buf));
    buf->st_mode = S_IFREG | 0600;   /* image-file semantics: no ioctls */
    buf->st_size = c->io.size;
    return 0;
}

static int nkdev_ioctl(struct ntfs_device *dev, unsigned long request, void *argp) {
    (void)dev; (void)request; (void)argp;
    errno = ENOTSUP;
    return -1;
}

static struct ntfs_device_operations nk_dev_ops = {
    .open   = nkdev_open,
    .close  = nkdev_close,
    .seek   = nkdev_seek,
    .read   = nkdev_read,
    .write  = nkdev_write,
    .pread  = nkdev_pread,
    .pwrite = nkdev_pwrite,
    .sync   = nkdev_sync,
    .stat   = nkdev_stat,
    .ioctl  = nkdev_ioctl,
};

nk_volume *nk_mount_io(const nk_io *io, char *errbuf, size_t errlen) {
    if (!io || !io->pread || io->size < 512 ||
        (!io->readonly && (!io->pwrite || !io->sync))) {
        errno = EINVAL;
        if (errbuf && errlen) snprintf(errbuf, errlen, "invalid or incomplete block IO callbacks");
        return NULL;
    }
    if (!io->readonly) {
        nk_io ro = *io;
        ro.readonly = 1;
        nk_volume *preflight = nk_mount_io(&ro, errbuf, errlen);
        if (!preflight) return NULL;
        int unsafe = preflight->vol->flags != 0 ||
                     ntfs_volume_check_hiberfile(preflight->vol, 0) != 0;
        int closed = nk_umount(preflight);
        if (unsafe || closed) {
            errno = EROFS;
            if (errbuf && errlen) snprintf(errbuf, errlen, "unsafe or unknown NTFS health; writable mount refused");
            return NULL;
        }
    }
    struct nk_devctx *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->io = *io;

    struct ntfs_device *dev = ntfs_device_alloc("fskit-block", 0, &nk_dev_ops, c);
    if (!dev) { free(c); return NULL; }

    ntfs_mount_flags flags = io->readonly ? NTFS_MNT_RDONLY : NTFS_MNT_NONE;
    ntfs_volume *vol = ntfs_device_mount(dev, flags);
    if (!vol) {
        if (errbuf && errlen)
            snprintf(errbuf, errlen, "ntfs_device_mount: %s", strerror(errno));
        ntfs_device_free(dev);
        free(c);
        return NULL;
    }
    nk_volume *v = calloc(1, sizeof(*v));
    if (!v) { ntfs_umount(vol, TRUE); free(c); return NULL; }
    v->vol = vol;
    v->devctx = c;
    return v;
}

int nk_umount(nk_volume *v) {
    if (!v) return -1;
    int r = v->vol ? ntfs_umount(v->vol, FALSE) : 0;  /* frees the device too */
    free(v->devctx);
    free(v);
    return r;
}

int nk_statvfs(nk_volume *v, long long *total_bytes, long long *free_bytes,
               int *cluster_size) {
    if (!v) return -1;
    ntfs_volume *vol = v->vol;
    if (ntfs_volume_get_free_space(vol) < 0) return -1;
    if (total_bytes)  *total_bytes  = (long long)vol->nr_clusters * vol->cluster_size;
    if (free_bytes)   *free_bytes   = (long long)vol->free_clusters * vol->cluster_size;
    if (cluster_size) *cluster_size = (int)vol->cluster_size;
    return 0;
}

int nk_label(nk_volume *v, char *buf, size_t buflen) {
    if (!v || !buf || buflen == 0) return -1;
    const char *name = v->vol->vol_name;
    snprintf(buf, buflen, "%s", name ? name : "");
    return 0;
}

/* Interix-style symlink: SYSTEM file whose data starts with "IntxLNK\1"
 * (the format ntfs_create_symlink writes, same as ntfs-3g's FUSE driver). */
static int is_intx_symlink(ntfs_attr *na) {
    if (!na || na->data_size < 10 || na->data_size > 4096 + 8) return 0;
    le64 magic = 0;
    if (ntfs_attr_pread(na, 0, sizeof(magic), &magic) != sizeof(magic)) return 0;
    return magic == INTX_SYMBOLIC_LINK;
}

static void fill_stat(ntfs_inode *ni, ntfs_attr *na, nk_stat *st) {
    memset(st, 0, sizeof(*st));
    st->is_dir = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? 1 : 0;
    st->inode = (uint64_t)ni->mft_no;
    st->is_symlink = (ni->flags & FILE_ATTR_REPARSE_POINT) ? 1 : 0;
    if (!st->is_symlink && (ni->flags & FILE_ATTR_SYSTEM) && is_intx_symlink(na))
        st->is_symlink = 1;
    if (na) {
        st->size = (long long)na->data_size;
        st->alloc_size = (long long)na->allocated_size;
        st->is_resident = NAttrNonResident(na) ? 0 : 1;
        st->koio_ok = 0; /* kernel-offloaded IO is not exposed */
    }
    st->atime = ntfs2timespec(ni->last_access_time).tv_sec;
    st->mtime = ntfs2timespec(ni->last_data_change_time).tv_sec;
    st->ctime = ntfs2timespec(ni->last_mft_change_time).tv_sec;
    st->btime = ntfs2timespec(ni->creation_time).tv_sec;
}

int nk_stat_path(nk_volume *v, const char *path, nk_stat *st) {
    if (!v || !st) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    ntfs_attr *na = NULL;
    if (!(ni->mrec->flags & MFT_RECORD_IS_DIRECTORY))
        na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    fill_stat(ni, na, st);
    if (na) ntfs_attr_close(na);
    ntfs_inode_close(ni);
    return 0;
}

struct list_ctx {
    nk_volume   *v;
    nk_dirent_cb cb;
    void        *ctx;
    int          stop;
};

static int nk_filldir(void *ctx, const ntfschar *name, const int name_len,
                      const int name_type, const s64 pos, const MFT_REF mref,
                      const unsigned dt_type) {
    (void)pos;
    struct list_ctx *lc = ctx;
    if (lc->stop) return 0;
    if (name_type == FILE_NAME_DOS) return 0;          /* skip 8.3 aliases */
    if (MREF(mref) < (u64)FILE_first_user) return 0;   /* skip $MFT & friends */

    char *utf8 = NULL;
    if (ntfs_ucstombs(name, name_len, &utf8, 0) < 0 || !utf8) {
        /* e.g. unpaired surrogate (legal on Windows): no UTF-8 form, and an
         * escaped name couldn't be looked up again — skip, but say so. */
        ntfs_log_error("readdir: skipping unconvertible name (inode %llu)\n",
                       (unsigned long long)MREF(mref));
        return 0;
    }

    int is_dot = utf8[0] == '.' &&
                 (utf8[1] == '\0' || (utf8[1] == '.' && utf8[2] == '\0'));
    if (!is_dot) {
        nk_dirent e = { .name = utf8, .is_dir = dt_type == NTFS_DT_DIR,
                        .size = 0, .inode = MREF(mref) };
        if (!e.is_dir) {
            ntfs_inode *ni = ntfs_inode_open(lc->v->vol, mref);
            if (ni) {
                ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
                if (na) { e.size = (long long)na->data_size; ntfs_attr_close(na); }
                ntfs_inode_close(ni);
            }
        }
        if (lc->cb(lc->ctx, &e) != 0) lc->stop = 1;
    }
    free(utf8);
    return 0;
}

int nk_list(nk_volume *v, const char *dir_path, nk_dirent_cb cb, void *ctx) {
    if (!v || !cb) return -1;
    ntfs_inode *dir = ntfs_pathname_to_inode(v->vol, NULL, dir_path);
    if (!dir) return -1;
    struct list_ctx lc = { v, cb, ctx, 0 };
    s64 pos = 0;
    int r = ntfs_readdir(dir, &pos, &lc, nk_filldir);
    ntfs_inode_close(dir);
    return r ? -1 : 0;
}

long long nk_read(nk_volume *v, const char *path, long long offset,
                  long long count, void *buf) {
    if (!v) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    long long n = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (na) {
        n = (long long)ntfs_attr_pread(na, offset, count, buf);
        ntfs_attr_close(na);
    }
    ntfs_inode_close(ni);
    return n;
}

long long nk_write(nk_volume *v, const char *path, long long offset,
                   long long count, const void *buf) {
    if (require_writable(v)) return -1;
    if (!v) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    long long n = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (na) {
        n = (long long)ntfs_attr_pwrite(na, offset, count, buf);
        ntfs_attr_close(na);
    }
    ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    if (ntfs_inode_close(ni) && n >= 0) n = -1;   /* flushes size/timestamps */
    return n;
}

static int create_node(nk_volume *v, const char *dir_path, const char *name,
                       mode_t type) {
    if (require_writable(v)) return -1;
    if (!v) return -1;
    ntfs_inode *dir = ntfs_pathname_to_inode(v->vol, NULL, dir_path);
    if (!dir) return -1;
    ntfschar *ucs = NULL;
    int len = ntfs_mbstoucs(name, &ucs);
    /* NTFS names are at most 255 UCS-2 units; (u8) casts must never wrap. */
    if (len <= 0 || len > 255 || !ucs) { free(ucs); ntfs_inode_close(dir); return -1; }
    ntfs_inode *ni = ntfs_create(dir, const_cpu_to_le32(0), ucs, (u8)len, type);
    free(ucs);
    int r = ni ? 0 : -1;
    if (ni && ntfs_inode_close(ni)) r = -1;
    if (ntfs_inode_close(dir)) r = -1;
    return r;
}

int nk_create(nk_volume *v, const char *dir_path, const char *name) {
    return create_node(v, dir_path, name, S_IFREG);
}

int nk_mkdir(nk_volume *v, const char *dir_path, const char *name) {
    return create_node(v, dir_path, name, S_IFDIR);
}

/* Split "/a/b/c" into parent "/a/b" (written into parent[]) and leaf "c". */
static const char *split_path(const char *path, char *parent, size_t plen_max) {
    const char *slash = strrchr(path, '/');
    if (!slash) return NULL;
    size_t plen = (size_t)(slash - path);
    if (plen == 0) { strcpy(parent, "/"); }
    else {
        if (plen >= plen_max) return NULL;
        memcpy(parent, path, plen);
        parent[plen] = '\0';
    }
    return slash + 1;
}

int nk_delete(nk_volume *v, const char *path) {
    if (require_writable(v)) return -1;
    if (!v || !path) return -1;
    size_t psize = strlen(path) + 2;   /* sized to the path: no length cap */
    char *parent = malloc(psize);
    const char *leaf = parent ? split_path(path, parent, psize) : NULL;
    ntfs_inode *ni = leaf ? ntfs_pathname_to_inode(v->vol, NULL, path) : NULL;
    ntfs_inode *dir = ni ? ntfs_pathname_to_inode(v->vol, NULL, parent) : NULL;
    free(parent);
    if (!dir) { if (ni) ntfs_inode_close(ni); return -1; }

    ntfschar *ucs = NULL;
    int len = ntfs_mbstoucs(leaf, &ucs);
    if (len <= 0 || len > 255 || !ucs) {
        free(ucs); ntfs_inode_close(dir); ntfs_inode_close(ni); return -1;
    }

    /* ntfs_delete consumes (closes) both inodes, success or failure. */
    int r = ntfs_delete(v->vol, path, ni, dir, ucs, (u8)len);
    free(ucs);
    return r ? -1 : 0;
}

/* Rename the way ntfs-3g's FUSE front end does: link under the new name,
 * then delete the old name. Works for files and directories. */
int nk_rename(nk_volume *v, const char *old_path, const char *new_dir,
              const char *new_name) {
    if (require_writable(v)) return -1;
    if (!v) return -1;

    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, old_path);
    if (!ni) return -1;
    ntfs_inode *dir = ntfs_pathname_to_inode(v->vol, NULL, new_dir);
    if (!dir) { ntfs_inode_close(ni); return -1; }

    ntfschar *ucs = NULL;
    int len = ntfs_mbstoucs(new_name, &ucs);
    if (len <= 0 || len > 255 || !ucs) {
        free(ucs); ntfs_inode_close(dir); ntfs_inode_close(ni); return -1;
    }

    /* POSIX (and ntfs-3g's FUSE rename): renaming onto another name of the
     * same inode is a no-op. */
    u64 ex = ntfs_inode_lookup_by_name(dir, ucs, len);
    if (ex != (u64)-1 && MREF(ex) == ni->mft_no) {
        free(ucs); ntfs_inode_close(dir); ntfs_inode_close(ni); return 0;
    }

    /* Remember both by MFT ref so a rollback never re-resolves paths. */
    u64 nref = nk_mref(ni), dref = nk_mref(dir);
    int r = ntfs_link(ni, dir, ucs, (u8)len);
    ntfs_inode_close(dir);
    ntfs_inode_close(ni);
    if (r) { free(ucs); return -1; }

    if (nk_delete(v, old_path) == 0) { free(ucs); return 0; }

    /* Deleting the old name failed — roll back the new link so the namespace
     * isn't left with two names for one file. */
    ntfs_inode *nni = ntfs_inode_open(v->vol, nref);
    ntfs_inode *ndir = ntfs_inode_open(v->vol, dref);
    if (nni && ndir)
        ntfs_delete(v->vol, NULL, nni, ndir, ucs, (u8)len);  /* consumes both */
    else {
        if (nni) ntfs_inode_close(nni);
        if (ndir) ntfs_inode_close(ndir);
    }
    free(ucs);
    return -1;
}

int nk_truncate(nk_volume *v, const char *path, long long size) {
    if (require_writable(v)) return -1;
    if (!v) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    int r = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (na) {
        r = ntfs_attr_truncate(na, size);
        ntfs_attr_close(na);
    }
    ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    if (ntfs_inode_close(ni)) r = -1;
    return r ? -1 : 0;
}

int nk_sync(nk_volume *v) {
    if (!v) return -1;
    return ntfs_device_sync(v->vol->dev) ? -1 : 0;
}

int nk_set_times(nk_volume *v, const char *path, long long atime,
                 long long mtime, long long btime) {
    if (require_writable(v)) return -1;
    if (!v) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    struct timespec ts = { 0, 0 };
    if (atime >= 0) { ts.tv_sec = (time_t)atime; ni->last_access_time = timespec2ntfs(ts); }
    if (mtime >= 0) { ts.tv_sec = (time_t)mtime; ni->last_data_change_time = timespec2ntfs(ts); }
    if (btime >= 0) { ts.tv_sec = (time_t)btime; ni->creation_time = timespec2ntfs(ts); }
    NInoFileNameSetDirty(ni);
    ntfs_inode_mark_dirty(ni);
    return ntfs_inode_close(ni) ? -1 : 0;
}

int nk_readlink(nk_volume *v, const char *path, char *buf, size_t buflen) {
    if (!v || !buf || buflen == 0) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    int r = -1;
    if (ni->flags & FILE_ATTR_REPARSE_POINT) {
        char *target = ntfs_make_symlink(ni, "/");
        if (target) {
            if (strlen(target) < buflen) { strcpy(buf, target); r = 0; }
            else errno = ENAMETOOLONG;
            free(target);
        }
    } else {
        /* Interix symlink: UCS-2 target follows the 8-byte IntxLNK magic. */
        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
        if (na && is_intx_symlink(na)) {
            s64 tlen_bytes = na->data_size - 8;
            ntfschar *ucs = malloc((size_t)tlen_bytes);
            if (ucs && ntfs_attr_pread(na, 8, tlen_bytes, ucs) == tlen_bytes) {
                char *utf8 = NULL;
                if (ntfs_ucstombs(ucs, (int)(tlen_bytes / 2), &utf8, 0) >= 0 && utf8) {
                    if (strlen(utf8) < buflen) { strcpy(buf, utf8); r = 0; }
                    else errno = ENAMETOOLONG;
                    free(utf8);
                }
            }
            free(ucs);
        }
        if (na) ntfs_attr_close(na);
    }
    ntfs_inode_close(ni);
    return r;
}

int nk_create_symlink(nk_volume *v, const char *dir_path, const char *name,
                      const char *target) {
    if (require_writable(v)) return -1;
    if (!v) return -1;
    ntfs_inode *dir = ntfs_pathname_to_inode(v->vol, NULL, dir_path);
    if (!dir) return -1;
    ntfschar *uname = NULL, *utarget = NULL;
    int nlen = ntfs_mbstoucs(name, &uname);
    int tlen = ntfs_mbstoucs(target, &utarget);
    int r = -1;
    if (nlen > 0 && nlen <= 255 && tlen > 0) {
        ntfs_inode *ni = ntfs_create_symlink(dir, const_cpu_to_le32(0),
                                             uname, (u8)nlen, utarget, tlen);
        if (ni) { r = ntfs_inode_close(ni) ? -1 : 0; }
    }
    free(uname);
    free(utarget);
    ntfs_inode_close(dir);
    return r;
}

int nk_is_dirty(nk_volume *v) {
    if (!v) return -1;
    return (v->vol->flags & VOLUME_IS_DIRTY) ? 1 : 0;
}

/* Read-only check only. DiskFerry never repairs or clears dirty state. */
int nk_fsck(const nk_io *io, int repair, char *errbuf, size_t errlen) {
    if (!io || repair) { errno = ENOTSUP; return -1; }
    nk_io ro = *io;
    ro.readonly = 1;
    nk_volume *v = nk_mount_io(&ro, errbuf, errlen);
    if (!v) return -1;
    int r = v->vol->flags != 0 ? 1 : 0;
    if (ntfs_volume_check_hiberfile(v->vol, 0) != 0) r = -2;
    if (nk_umount(v)) return -1;
    return r;
}

/* ---- volume label ---- */

int nk_set_label(nk_volume *v, const char *label) {
    if (require_writable(v)) return -1;
    if (!v || !label) return -1;
    ntfschar *ucs = NULL;
    int len = ntfs_mbstoucs(label, &ucs);
    if (len < 0 || len > 128 || !ucs) { free(ucs); return -1; }
    int r = ntfs_volume_rename(v->vol, ucs, len);
    free(ucs);
    return r ? -1 : 0;
}

/* ---- extended attributes as NTFS named data streams (ADS) ----
 * macOS xattrs map 1:1 onto alternate data streams, so they round-trip to
 * Windows (visible as `file:name`) and back — no AppleDouble ._ files. */

static ntfschar *xattr_ucs(const char *name, int *out_len) {
    ntfschar *ucs = NULL;
    int len = ntfs_mbstoucs(name, &ucs);
    if (len <= 0 || len > 255 || !ucs) { free(ucs); return NULL; }
    *out_len = len;
    return ucs;
}

int nk_xattr_list(nk_volume *v, const char *path, nk_name_cb cb, void *ctx) {
    if (!v || !cb) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) return -1;
    int r = 0;
    ntfs_attr_search_ctx *sctx = ntfs_attr_get_search_ctx(ni, NULL);
    if (!sctx) { ntfs_inode_close(ni); return -1; }
    while (!ntfs_attr_lookup(AT_DATA, NULL, 0, CASE_SENSITIVE, 0, NULL, 0, sctx)) {
        if (!sctx->attr->name_length) continue;    /* unnamed = file data */
        char *utf8 = NULL;
        ntfschar *name = (ntfschar *)((u8 *)sctx->attr
                                      + le16_to_cpu(sctx->attr->name_offset));
        if (ntfs_ucstombs(name, sctx->attr->name_length, &utf8, 0) >= 0 && utf8) {
            if (cb(ctx, utf8)) { free(utf8); break; }
            free(utf8);
        } else {
            ntfs_log_error("xattr_list: skipping unconvertible stream name\n");
        }
    }
    ntfs_attr_put_search_ctx(sctx);
    ntfs_inode_close(ni);
    return r;
}

long long nk_xattr_get(nk_volume *v, const char *path, const char *name,
                       void *buf, long long bufsize) {
    if (!v || !name) return -1;
    int nlen = 0;
    ntfschar *ucs = xattr_ucs(name, &nlen);
    if (!ucs) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) { free(ucs); return -1; }
    long long r = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, ucs, nlen);
    if (na) {
        if (!buf || bufsize == 0) {
            r = na->data_size;             /* size query */
        } else if (bufsize < na->data_size) {
            errno = ERANGE;                /* never hand back a partial value */
        } else {
            r = ntfs_attr_pread(na, 0, na->data_size, buf);
        }
        ntfs_attr_close(na);
    }
    ntfs_inode_close(ni);
    free(ucs);
    return r;
}

int nk_xattr_set(nk_volume *v, const char *path, const char *name,
                 const void *buf, long long size) {
    if (require_writable(v)) return -1;
    if (!v || !name || size < 0) return -1;
    int nlen = 0;
    ntfschar *ucs = xattr_ucs(name, &nlen);
    if (!ucs) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) { free(ucs); return -1; }
    int r = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, ucs, nlen);
    if (na) {
        /* replace: overwrite FIRST, then shrink — a failed write leaves the
         * old (or mixed) value, never a zeroed stream */
        if ((size == 0 || ntfs_attr_pwrite(na, 0, size, buf) == size) &&
            !ntfs_attr_truncate(na, size))
            r = 0;
        ntfs_attr_close(na);
    } else if (!ntfs_attr_add(ni, AT_DATA, ucs, nlen,
                              (u8 *)(size ? buf : (const void *)""), size)) {
        r = 0;
    }
    ntfs_inode_mark_dirty(ni);
    if (ntfs_inode_close(ni)) r = -1;
    free(ucs);
    return r;
}

int nk_xattr_remove(nk_volume *v, const char *path, const char *name) {
    if (require_writable(v)) return -1;
    if (!v || !name) return -1;
    int nlen = 0;
    ntfschar *ucs = xattr_ucs(name, &nlen);
    if (!ucs) return -1;
    ntfs_inode *ni = ntfs_pathname_to_inode(v->vol, NULL, path);
    if (!ni) { free(ucs); return -1; }
    int r = -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, ucs, nlen);
    if (na) {
        r = ntfs_attr_rm(na) ? -1 : 0;     /* rm never frees na */
        ntfs_attr_close(na);
    }
    ntfs_inode_mark_dirty(ni);
    if (ntfs_inode_close(ni)) r = -1;
    free(ucs);
    return r;
}

const char *nk_engine_version(void) {
    return "libntfs-3g 2026.9.28 (DiskFerry experimental FSKit)";
}
