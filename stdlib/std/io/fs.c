/* std.io.fs — portable filesystem shim for FLang.
 *
 * Exposes directory iteration with platform differences hidden behind a
 * stable ABI. The FLang side never sees errno or Win32 codes — OS errors
 * are translated directly into FsError discriminants inside this shim.
 *
 * FsError tag assignments MUST match the `FsError` enum order in fs.f:
 *   0 = NotFound
 *   1 = PermissionDenied
 *   2 = NotADirectory
 *   3 = NameTooLong
 *   4 = NotSupported
 *   5 = InvalidArgument
 *   6 = IOError
 *
 * Return conventions (status codes are independent of FsError):
 *   __flang_fs_opendir  : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_readdir  : 0 = entry produced, 1 = end-of-dir, 2 = error
 *   __flang_fs_closedir : 0 = OK, 1 = error (code in *out_err)
 *
 * "." and ".." are filtered inside the shim — callers never see them.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

/* FsError discriminants — see fs.f for the enum declaration. */
#define FS_NOT_FOUND          0
#define FS_PERMISSION_DENIED  1
#define FS_NOT_A_DIRECTORY    2
#define FS_NAME_TOO_LONG      3
#define FS_NOT_SUPPORTED      4
#define FS_INVALID_ARGUMENT   5
#define FS_IO_ERROR           6

/* Return codes. */
#define R_OK     0
#define R_EOF    1
#define R_ERR    2

/* Some POSIX systems may omit these — provide fallbacks for compilation. */
#ifndef ENAMETOOLONG
#define ENAMETOOLONG 36
#endif
#ifndef ENOTDIR
#define ENOTDIR 20
#endif
#ifndef ENOSYS
#define ENOSYS 38
#endif

static int is_dot_or_dotdot(const char* s) {
    return s[0] == '.' &&
           (s[1] == '\0' || (s[1] == '.' && s[2] == '\0'));
}

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdlib.h>

typedef struct {
    HANDLE handle;
    WIN32_FIND_DATAA data;
    int has_pending;
    int end;
} WinDir;

static int32_t fs_err_from_win32(DWORD e) {
    switch (e) {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:
        case ERROR_INVALID_DRIVE:
        case ERROR_BAD_NETPATH:
            return FS_NOT_FOUND;
        case ERROR_ACCESS_DENIED:
        case ERROR_SHARING_VIOLATION:
        case ERROR_LOCK_VIOLATION:
            return FS_PERMISSION_DENIED;
        case ERROR_DIRECTORY:
            return FS_NOT_A_DIRECTORY;
        case ERROR_FILENAME_EXCED_RANGE:
        case ERROR_BUFFER_OVERFLOW:
            return FS_NAME_TOO_LONG;
        case ERROR_NOT_SUPPORTED:
        case ERROR_CALL_NOT_IMPLEMENTED:
            return FS_NOT_SUPPORTED;
        case ERROR_INVALID_PARAMETER:
        case ERROR_INVALID_HANDLE:
            return FS_INVALID_ARGUMENT;
        default:
            return FS_IO_ERROR;
    }
}

int __flang_fs_opendir(const char* path, void** out_dir, int32_t* out_err) {
    *out_dir = NULL;
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return R_ERR; }

    size_t n = strlen(path);
    if (n == 0) { *out_err = FS_NOT_FOUND; return R_ERR; }
    if (n + 3 > MAX_PATH) { *out_err = FS_NAME_TOO_LONG; return R_ERR; }

    char pattern[MAX_PATH + 4];
    memcpy(pattern, path, n);
    char last = path[n - 1];
    size_t plen = n;
    if (last != '\\' && last != '/') {
        pattern[plen++] = '\\';
    }
    pattern[plen++] = '*';
    pattern[plen] = '\0';

    WinDir* d = (WinDir*)malloc(sizeof(WinDir));
    if (!d) { *out_err = FS_IO_ERROR; return R_ERR; }

    d->handle = FindFirstFileA(pattern, &d->data);
    if (d->handle == INVALID_HANDLE_VALUE) {
        *out_err = fs_err_from_win32(GetLastError());
        free(d);
        return R_ERR;
    }
    d->has_pending = 1;
    d->end = 0;
    *out_dir = (void*)d;
    return R_OK;
}

int __flang_fs_readdir(void* dir, uint8_t* name_buf, size_t cap,
                       size_t* out_len, int32_t* out_kind, int32_t* out_err) {
    if (!dir || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return R_ERR; }
    WinDir* d = (WinDir*)dir;

    for (;;) {
        if (d->end) return R_EOF;

        if (!d->has_pending) {
            if (!FindNextFileA(d->handle, &d->data)) {
                DWORD e = GetLastError();
                d->end = 1;
                if (e == ERROR_NO_MORE_FILES) return R_EOF;
                *out_err = fs_err_from_win32(e);
                return R_ERR;
            }
        }
        d->has_pending = 0;

        const char* name = d->data.cFileName;
        if (is_dot_or_dotdot(name)) continue;

        size_t n = strlen(name);
        if (n + 1 > cap) { *out_err = FS_NAME_TOO_LONG; return R_ERR; }
        memcpy(name_buf, name, n);
        name_buf[n] = 0;
        *out_len = n;

        DWORD a = d->data.dwFileAttributes;
        if (a & FILE_ATTRIBUTE_REPARSE_POINT) {
            *out_kind = 2;
        } else if (a & FILE_ATTRIBUTE_DIRECTORY) {
            *out_kind = 1;
        } else if (a & (FILE_ATTRIBUTE_DEVICE | FILE_ATTRIBUTE_VIRTUAL)) {
            *out_kind = 3;
        } else {
            *out_kind = 0;
        }
        return R_OK;
    }
}

int __flang_fs_closedir(void* dir, int32_t* out_err) {
    if (!dir) return R_OK;
    WinDir* d = (WinDir*)dir;
    int rc = R_OK;
    if (d->handle != INVALID_HANDLE_VALUE && !FindClose(d->handle)) {
        *out_err = fs_err_from_win32(GetLastError());
        rc = R_ERR;
    }
    free(d);
    return rc;
}

#else

#include <dirent.h>
#include <sys/stat.h>

static int32_t fs_err_from_errno(int e) {
    switch (e) {
        case ENOENT:       return FS_NOT_FOUND;
        case EACCES:
        case EPERM:        return FS_PERMISSION_DENIED;
        case ENOTDIR:      return FS_NOT_A_DIRECTORY;
        case ENAMETOOLONG: return FS_NAME_TOO_LONG;
        case ENOSYS:       return FS_NOT_SUPPORTED;
        case EINVAL:       return FS_INVALID_ARGUMENT;
        default:           return FS_IO_ERROR;
    }
}

int __flang_fs_opendir(const char* path, void** out_dir, int32_t* out_err) {
    DIR* d = opendir(path);
    if (!d) {
        *out_dir = NULL;
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return R_ERR;
    }
    *out_dir = (void*)d;
    return R_OK;
}

int __flang_fs_readdir(void* dir, uint8_t* name_buf, size_t cap,
                       size_t* out_len, int32_t* out_kind, int32_t* out_err) {
    if (!dir || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return R_ERR; }
    DIR* d = (DIR*)dir;
    for (;;) {
        errno = 0;
        struct dirent* ent = readdir(d);
        if (!ent) {
            if (errno == 0) return R_EOF;
            *out_err = fs_err_from_errno(errno);
            return R_ERR;
        }
        if (is_dot_or_dotdot(ent->d_name)) continue;

        size_t n = strlen(ent->d_name);
        if (n + 1 > cap) { *out_err = FS_NAME_TOO_LONG; return R_ERR; }
        memcpy(name_buf, ent->d_name, n);
        name_buf[n] = 0;
        *out_len = n;
        switch (ent->d_type) {
            case DT_REG: *out_kind = 0; break;
            case DT_DIR: *out_kind = 1; break;
            case DT_LNK: *out_kind = 2; break;
            default:     *out_kind = 3; break;
        }
        return R_OK;
    }
}

int __flang_fs_closedir(void* dir, int32_t* out_err) {
    if (!dir) return R_OK;
    if (closedir((DIR*)dir) == 0) return R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return R_ERR;
}

#endif
