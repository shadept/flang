/* std.io.internal.fs — the whole OS surface for FLang's io modules.
 *
 * Every syscall the io modules make lives here, behind a stable ABI. The
 * FLang side never sees errno, Win32 codes, or O_* flag values — all three
 * differ per platform and all three are resolved in this file. std.io.fs,
 * std.io.file and std.io.dir are built on top and add no foreigns of their
 * own; that is the point of the module.
 *
 * Open modes (portable, mapped to O_* / _O_* here):
 *   0 = read, 1 = write (create+truncate), 2 = append (create)
 *
 * FsError tag assignments MUST match the `FsError` enum order in fs.f:
 *   0 = NotFound
 *   1 = PermissionDenied
 *   2 = NotADirectory
 *   3 = NameTooLong
 *   4 = NotSupported
 *   5 = InvalidArgument
 *   6 = IOError
 *   7 = AlreadyExists
 *   8 = NotEmpty
 *
 * Return conventions (status codes are independent of FsError):
 *   __flang_fs_opendir  : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_readdir  : 0 = entry produced, 1 = end-of-dir, 2 = error
 *   __flang_fs_closedir : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_mkdir    : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_unlink   : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_rmdir    : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_rename   : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_open     : 0 = OK, 1 = error (fd in *out_fd)
 *   __flang_fs_close    : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_read     : 0 = OK, 1 = error (count in *out_n; 0 = EOF)
 *   __flang_fs_write    : 0 = OK, 1 = error (count in *out_n)
 *   __flang_fs_getcwd   : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_realpath : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_temp_dir : 0 = OK, 1 = error (code in *out_err)
 *   __flang_fs_set_binary : 0 = OK, 1 = error
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
#define FS_ALREADY_EXISTS     7
#define FS_NOT_EMPTY          8

/* Return codes. Prefixed because the unprefixed names collide with system
 * headers: <unistd.h> defines R_OK as 4 (the access(2) read-permission bit),
 * which silently redefined a local `#define R_OK 0` and made every shim below
 * the include report success as failure. */
#define FS_R_OK  0
#define FS_R_EOF 1
#define FS_R_ERR 2


static int is_dot_or_dotdot(const char* s) {
    return s[0] == '.' &&
           (s[1] == '\0' || (s[1] == '.' && s[2] == '\0'));
}

/* POSIX errno → FsError. Shared with the Windows branch because the CRT's
 * _stat64 sets errno with POSIX codes on Windows too. */
/* Never invent a numeric fallback for an errno the platform did not define:
 * the values differ per OS (ENAMETOOLONG is 36 on Linux and 63 on macOS,
 * ENOSYS 38 vs 78, ENOTEMPTY 39 vs 66), so a guessed constant either maps the
 * wrong error or collides with a real one and turns into a duplicate case.
 * Guard the label instead - an absent errno then costs one unreachable
 * mapping, not a silently wrong one. */
static int32_t fs_err_from_errno(int e) {
    switch (e) {
        case ENOENT:       return FS_NOT_FOUND;
        case EACCES:
        case EPERM:        return FS_PERMISSION_DENIED;
        case EINVAL:       return FS_INVALID_ARGUMENT;
        case EEXIST:       return FS_ALREADY_EXISTS;
#ifdef ENOTDIR
        case ENOTDIR:      return FS_NOT_A_DIRECTORY;
#endif
#ifdef ENAMETOOLONG
        case ENAMETOOLONG: return FS_NAME_TOO_LONG;
#endif
#ifdef ENOSYS
        case ENOSYS:       return FS_NOT_SUPPORTED;
#endif
#ifdef ENOTEMPTY
        case ENOTEMPTY:    return FS_NOT_EMPTY;
#endif
        default:           return FS_IO_ERROR;
    }
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
        case ERROR_ALREADY_EXISTS:
        case ERROR_FILE_EXISTS:
            return FS_ALREADY_EXISTS;
        case ERROR_DIR_NOT_EMPTY:
            return FS_NOT_EMPTY;
        default:
            return FS_IO_ERROR;
    }
}

int __flang_fs_opendir(const char* path, void** out_dir, int32_t* out_err) {
    *out_dir = NULL;
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }

    size_t n = strlen(path);
    if (n == 0) { *out_err = FS_NOT_FOUND; return FS_R_ERR; }
    if (n + 3 > MAX_PATH) { *out_err = FS_NAME_TOO_LONG; return FS_R_ERR; }

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
    if (!d) { *out_err = FS_IO_ERROR; return FS_R_ERR; }

    d->handle = FindFirstFileA(pattern, &d->data);
    if (d->handle == INVALID_HANDLE_VALUE) {
        *out_err = fs_err_from_win32(GetLastError());
        free(d);
        return FS_R_ERR;
    }
    d->has_pending = 1;
    d->end = 0;
    *out_dir = (void*)d;
    return FS_R_OK;
}

int __flang_fs_readdir(void* dir, uint8_t* name_buf, size_t cap,
                       size_t* out_len, int32_t* out_kind, int32_t* out_err) {
    if (!dir || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    WinDir* d = (WinDir*)dir;

    for (;;) {
        if (d->end) return FS_R_EOF;

        if (!d->has_pending) {
            if (!FindNextFileA(d->handle, &d->data)) {
                DWORD e = GetLastError();
                d->end = 1;
                if (e == ERROR_NO_MORE_FILES) return FS_R_EOF;
                *out_err = fs_err_from_win32(e);
                return FS_R_ERR;
            }
        }
        d->has_pending = 0;

        const char* name = d->data.cFileName;
        if (is_dot_or_dotdot(name)) continue;

        size_t n = strlen(name);
        if (n + 1 > cap) { *out_err = FS_NAME_TOO_LONG; return FS_R_ERR; }
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
        return FS_R_OK;
    }
}

int __flang_fs_closedir(void* dir, int32_t* out_err) {
    if (!dir) return FS_R_OK;
    WinDir* d = (WinDir*)dir;
    int rc = FS_R_OK;
    if (d->handle != INVALID_HANDLE_VALUE && !FindClose(d->handle)) {
        *out_err = fs_err_from_win32(GetLastError());
        rc = FS_R_ERR;
    }
    free(d);
    return rc;
}

#include <sys/types.h>
#include <sys/stat.h>
#include <direct.h>
#include <io.h>

int __flang_fs_mkdir(const char* path, int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (_mkdir(path) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

int __flang_fs_unlink(const char* path, int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (_unlink(path) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

int __flang_fs_rmdir(const char* path, int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (_rmdir(path) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

/* MoveFileEx rather than the CRT rename: the CRT fails when the destination
 * exists, while POSIX rename replaces it. Matching POSIX keeps the FLang API
 * one behaviour instead of two. */
int __flang_fs_rename(const char* from, const char* to, int32_t* out_err) {
    if (!from || !to) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (MoveFileExA(from, to, MOVEFILE_REPLACE_EXISTING)) return FS_R_OK;
    *out_err = fs_err_from_win32(GetLastError());
    return FS_R_ERR;
}

int __flang_fs_stat(const char* path,
                    int32_t* out_kind,
                    uint64_t* out_size,
                    int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    struct __stat64 st;
    if (_stat64(path, &st) != 0) {
        /* _stat64 is a CRT function — reports via errno, not GetLastError. */
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    if (st.st_mode & _S_IFDIR) {
        *out_kind = 1;
    } else if (st.st_mode & _S_IFREG) {
        *out_kind = 0;
    } else {
        *out_kind = 3;
    }
    *out_size = (uint64_t)st.st_size;
    return FS_R_OK;
}

#include <fcntl.h>

static int fs_open_flags(int32_t mode) {
    switch (mode) {
        case 0:  return _O_RDONLY | _O_BINARY;
        case 1:  return _O_WRONLY | _O_CREAT | _O_TRUNC | _O_BINARY;
        default: return _O_WRONLY | _O_CREAT | _O_APPEND | _O_BINARY;
    }
}

int __flang_fs_open(const char* path, int32_t mode, int32_t* out_fd, int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    int fd = _open(path, fs_open_flags(mode), _S_IREAD | _S_IWRITE);
    if (fd < 0) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    *out_fd = (int32_t)fd;
    return FS_R_OK;
}

int __flang_fs_close(int32_t fd, int32_t* out_err) {
    if (_close((int)fd) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

int __flang_fs_read(int32_t fd, uint8_t* buf, size_t len, size_t* out_n, int32_t* out_err) {
    if (!buf) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    int n = _read((int)fd, buf, (unsigned int)len);
    if (n < 0) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    *out_n = (size_t)n;
    return FS_R_OK;
}

int __flang_fs_write(int32_t fd, const uint8_t* buf, size_t len, size_t* out_n, int32_t* out_err) {
    if (!buf) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    int n = _write((int)fd, buf, (unsigned int)len);
    if (n < 0) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    *out_n = (size_t)n;
    return FS_R_OK;
}

/* The CRT opens fds 0/1/2 in text mode: reads collapse CRLF and stop at ^Z, writes expand
 * \n to \r\n. Byte-exact protocols over the standard streams must switch them to binary. */
int __flang_fs_set_binary(int32_t fd) {
    return _setmode((int)fd, _O_BINARY) < 0 ? FS_R_ERR : FS_R_OK;
}

/* Copies `src` into `buf`, reporting FS_NAME_TOO_LONG rather than truncating.
 * Shared by the three "OS hands us a path" entry points below. */
static int fs_emit_path(const char* src, uint8_t* buf, size_t cap,
                        size_t* out_len, int32_t* out_err) {
    size_t n = strlen(src);
    if (n + 1 > cap) { *out_err = FS_NAME_TOO_LONG; return FS_R_ERR; }
    memcpy(buf, src, n);
    buf[n] = 0;
    *out_len = n;
    return FS_R_OK;
}

int __flang_fs_getcwd(uint8_t* buf, size_t cap, size_t* out_len, int32_t* out_err) {
    if (!buf || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (!_getcwd((char*)buf, (int)cap)) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    *out_len = strlen((char*)buf);
    return FS_R_OK;
}

int __flang_fs_realpath(const char* path, uint8_t* buf, size_t cap,
                        size_t* out_len, int32_t* out_err) {
    if (!path || !buf || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    char resolved[MAX_PATH];
    if (!_fullpath(resolved, path, MAX_PATH)) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    /* _fullpath is lexical: confirm the target exists, as realpath(3) does. */
    struct __stat64 st;
    if (_stat64(resolved, &st) != 0) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    return fs_emit_path(resolved, buf, cap, out_len, out_err);
}

int __flang_fs_temp_dir(uint8_t* buf, size_t cap, size_t* out_len, int32_t* out_err) {
    if (!buf || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    char tmp[MAX_PATH + 1];
    DWORD n = GetTempPathA(MAX_PATH + 1, tmp);
    if (n == 0) { *out_err = fs_err_from_win32(GetLastError()); return FS_R_ERR; }
    /* GetTempPath always returns a trailing separator; drop it for consistency
     * with the POSIX side, which never has one. */
    if (n > 1 && (tmp[n - 1] == '\\' || tmp[n - 1] == '/')) tmp[n - 1] = 0;
    return fs_emit_path(tmp, buf, cap, out_len, out_err);
}


#else

#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>

int __flang_fs_opendir(const char* path, void** out_dir, int32_t* out_err) {
    DIR* d = opendir(path);
    if (!d) {
        *out_dir = NULL;
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    *out_dir = (void*)d;
    return FS_R_OK;
}

int __flang_fs_readdir(void* dir, uint8_t* name_buf, size_t cap,
                       size_t* out_len, int32_t* out_kind, int32_t* out_err) {
    if (!dir || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    DIR* d = (DIR*)dir;
    for (;;) {
        errno = 0;
        struct dirent* ent = readdir(d);
        if (!ent) {
            if (errno == 0) return FS_R_EOF;
            *out_err = fs_err_from_errno(errno);
            return FS_R_ERR;
        }
        if (is_dot_or_dotdot(ent->d_name)) continue;

        size_t n = strlen(ent->d_name);
        if (n + 1 > cap) { *out_err = FS_NAME_TOO_LONG; return FS_R_ERR; }
        memcpy(name_buf, ent->d_name, n);
        name_buf[n] = 0;
        *out_len = n;
        switch (ent->d_type) {
            case DT_REG: *out_kind = 0; break;
            case DT_DIR: *out_kind = 1; break;
            case DT_LNK: *out_kind = 2; break;
            default:     *out_kind = 3; break;
        }
        return FS_R_OK;
    }
}

int __flang_fs_closedir(void* dir, int32_t* out_err) {
    if (!dir) return FS_R_OK;
    if (closedir((DIR*)dir) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

int __flang_fs_mkdir(const char* path, int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (mkdir(path, 0777) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

int __flang_fs_unlink(const char* path, int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (unlink(path) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

int __flang_fs_rmdir(const char* path, int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (rmdir(path) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

int __flang_fs_rename(const char* from, const char* to, int32_t* out_err) {
    if (!from || !to) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (rename(from, to) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

int __flang_fs_stat(const char* path,
                    int32_t* out_kind,
                    uint64_t* out_size,
                    int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    struct stat st;
    if (stat(path, &st) != 0) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    if (S_ISDIR(st.st_mode))       *out_kind = 1;
    else if (S_ISREG(st.st_mode))  *out_kind = 0;
#ifdef S_ISLNK
    else if (S_ISLNK(st.st_mode))  *out_kind = 2;  /* unreachable: stat follows */
#endif
    else                           *out_kind = 3;
    *out_size = (uint64_t)st.st_size;
    return FS_R_OK;
}


#include <fcntl.h>
#include <stdlib.h>

static int fs_open_flags(int32_t mode) {
    switch (mode) {
        case 0:  return O_RDONLY;
        case 1:  return O_WRONLY | O_CREAT | O_TRUNC;
        default: return O_WRONLY | O_CREAT | O_APPEND;
    }
}

int __flang_fs_open(const char* path, int32_t mode, int32_t* out_fd, int32_t* out_err) {
    if (!path) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    int fd = open(path, fs_open_flags(mode), 0666);
    if (fd < 0) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    *out_fd = (int32_t)fd;
    return FS_R_OK;
}

int __flang_fs_close(int32_t fd, int32_t* out_err) {
    if (close((int)fd) == 0) return FS_R_OK;
    *out_err = fs_err_from_errno(errno ? errno : EIO);
    return FS_R_ERR;
}

int __flang_fs_read(int32_t fd, uint8_t* buf, size_t len, size_t* out_n, int32_t* out_err) {
    if (!buf) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    ssize_t n = read((int)fd, buf, len);
    if (n < 0) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    *out_n = (size_t)n;
    return FS_R_OK;
}

int __flang_fs_write(int32_t fd, const uint8_t* buf, size_t len, size_t* out_n, int32_t* out_err) {
    if (!buf) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    ssize_t n = write((int)fd, buf, len);
    if (n < 0) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    *out_n = (size_t)n;
    return FS_R_OK;
}

/* POSIX fds have no text mode; nothing to switch. */
int __flang_fs_set_binary(int32_t fd) {
    (void)fd;
    return FS_R_OK;
}

/* Copies `src` into `buf`, reporting FS_NAME_TOO_LONG rather than truncating.
 * Shared by the three "OS hands us a path" entry points below. */
static int fs_emit_path(const char* src, uint8_t* buf, size_t cap,
                        size_t* out_len, int32_t* out_err) {
    size_t n = strlen(src);
    if (n + 1 > cap) { *out_err = FS_NAME_TOO_LONG; return FS_R_ERR; }
    memcpy(buf, src, n);
    buf[n] = 0;
    *out_len = n;
    return FS_R_OK;
}

int __flang_fs_getcwd(uint8_t* buf, size_t cap, size_t* out_len, int32_t* out_err) {
    if (!buf || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    if (!getcwd((char*)buf, cap)) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    *out_len = strlen((char*)buf);
    return FS_R_OK;
}

int __flang_fs_realpath(const char* path, uint8_t* buf, size_t cap,
                        size_t* out_len, int32_t* out_err) {
    if (!path || !buf || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    /* PATH_MAX is not guaranteed to be defined; realpath(NULL) allocates
     * exactly the right size and is the portable form. */
    char* resolved = realpath(path, NULL);
    if (!resolved) {
        *out_err = fs_err_from_errno(errno ? errno : EIO);
        return FS_R_ERR;
    }
    int rc = fs_emit_path(resolved, buf, cap, out_len, out_err);
    free(resolved);
    return rc;
}

int __flang_fs_temp_dir(uint8_t* buf, size_t cap, size_t* out_len, int32_t* out_err) {
    if (!buf || cap == 0) { *out_err = FS_INVALID_ARGUMENT; return FS_R_ERR; }
    const char* tmp = getenv("TMPDIR");
    if (!tmp || !tmp[0]) tmp = "/tmp";

    /* Drop a trailing separator so callers can always join with one. */
    size_t n = strlen(tmp);
    while (n > 1 && tmp[n - 1] == '/') n--;
    if (n + 1 > cap) { *out_err = FS_NAME_TOO_LONG; return FS_R_ERR; }
    memcpy(buf, tmp, n);
    buf[n] = 0;
    *out_len = n;
    return FS_R_OK;
}

#endif
