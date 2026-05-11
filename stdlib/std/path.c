/* std.path — cross-platform shim.
 *
 * Currently exposes only `__flang_path_getcwd`. Path manipulation lives
 * entirely in the FLang side; only operations that touch the OS need a
 * shim. PathError discriminants MUST match the enum order in path.f:
 *
 *   0 = IOError
 *   1 = NameTooLong
 *   2 = NotFound
 *   3 = PermissionDenied
 *   4 = InvalidArgument
 *
 * Return codes:
 *   0 = OK
 *   1 = error (code in *out_err)
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

#define PATH_IOERR             0
#define PATH_NAME_TOO_LONG     1
#define PATH_NOT_FOUND         2
#define PATH_PERMISSION_DENIED 3
#define PATH_INVALID_ARGUMENT  4

#define R_OK  0
#define R_ERR 1

static int32_t path_err_from_errno(int e) {
    switch (e) {
        case ENOENT:       return PATH_NOT_FOUND;
        case EACCES:
        case EPERM:        return PATH_PERMISSION_DENIED;
#ifdef ENAMETOOLONG
        case ENAMETOOLONG: return PATH_NAME_TOO_LONG;
#endif
        case EINVAL:       return PATH_INVALID_ARGUMENT;
        case ERANGE:       return PATH_NAME_TOO_LONG;
        default:           return PATH_IOERR;
    }
}

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

int __flang_path_getcwd(uint8_t* buf, size_t cap, size_t* out_len, int32_t* out_err) {
    if (!buf || cap == 0) { *out_err = PATH_INVALID_ARGUMENT; return R_ERR; }

    /* GetCurrentDirectoryA returns the length without the terminator on success;
     * if the buffer is too small it returns the required length INCLUDING the
     * terminator. */
    DWORD n = GetCurrentDirectoryA((DWORD)cap, (LPSTR)buf);
    if (n == 0) {
        DWORD e = GetLastError();
        switch (e) {
            case ERROR_ACCESS_DENIED: *out_err = PATH_PERMISSION_DENIED; break;
            case ERROR_FILE_NOT_FOUND:
            case ERROR_PATH_NOT_FOUND: *out_err = PATH_NOT_FOUND; break;
            case ERROR_INSUFFICIENT_BUFFER:
            case ERROR_BUFFER_OVERFLOW:
            case ERROR_FILENAME_EXCED_RANGE: *out_err = PATH_NAME_TOO_LONG; break;
            default: *out_err = PATH_IOERR; break;
        }
        return R_ERR;
    }
    if ((size_t)n >= cap) {
        /* Required buffer didn't fit. */
        *out_err = PATH_NAME_TOO_LONG;
        return R_ERR;
    }
    *out_len = (size_t)n;
    return R_OK;
}

#else

#include <unistd.h>

int __flang_path_getcwd(uint8_t* buf, size_t cap, size_t* out_len, int32_t* out_err) {
    if (!buf || cap == 0) { *out_err = PATH_INVALID_ARGUMENT; return R_ERR; }
    if (!getcwd((char*)buf, cap)) {
        *out_err = path_err_from_errno(errno ? errno : EIO);
        return R_ERR;
    }
    *out_len = strlen((const char*)buf);
    return R_OK;
}

#endif
