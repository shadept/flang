/* std.process — child process and pipe shim.
 *
 * ProcessError discriminants MUST match `ProcessError` in process.f:
 *   0 = NotFound
 *   1 = PermissionDenied
 *   2 = IOError
 *   3 = InvalidArgument
 *
 * Stdio modes (process.f's `Stdio` enum):
 *   0 = Inherit, 1 = Null, 2 = Pipe.
 *
 * spawn / wait / kill return 0 on success, 1 on error (code in *out_err).
 * Pipe I/O follows POSIX conventions: returns byte count, 0 = EOF, -1 = error.
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>

#define PROC_NOT_FOUND          0
#define PROC_PERMISSION_DENIED  1
#define PROC_IO_ERROR           2
#define PROC_INVALID_ARGUMENT   3

#define STDIO_INHERIT 0
#define STDIO_NULL    1
#define STDIO_PIPE    2

#define R_OK  0
#define R_ERR 1

static int32_t proc_err_from_errno(int e) {
    switch (e) {
        case ENOENT: return PROC_NOT_FOUND;
        case EACCES:
        case EPERM:  return PROC_PERMISSION_DENIED;
        case EINVAL: return PROC_INVALID_ARGUMENT;
        default:     return PROC_IO_ERROR;
    }
}

/* Build a NULL-terminated char** from a packed uintptr_t array. Caller frees. */
static char** materialize_argv(const uintptr_t* packed, size_t n) {
    char** out = (char**)malloc((n + 1) * sizeof(char*));
    if (!out) return NULL;
    for (size_t i = 0; i < n; i++) out[i] = (char*)(uintptr_t)packed[i];
    out[n] = NULL;
    return out;
}

#ifdef _WIN32

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <io.h>
#include <fcntl.h>

extern char** environ;

static int32_t proc_err_from_win32(DWORD e) {
    switch (e) {
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:
            return PROC_NOT_FOUND;
        case ERROR_ACCESS_DENIED:
            return PROC_PERMISSION_DENIED;
        case ERROR_INVALID_PARAMETER:
            return PROC_INVALID_ARGUMENT;
        default:
            return PROC_IO_ERROR;
    }
}

/* Append a CreateProcess-quoted form of `arg` to `out`. Follows the parsing
 * rules used by MSVCRT and most CRTs: backslashes only need doubling when
 * they immediately precede a quote. */
static int append_quoted(char** out, size_t* out_len, size_t* out_cap, const char* arg) {
    size_t need = strlen(arg) * 2 + 3;
    if (*out_len + need + 1 > *out_cap) {
        size_t cap = (*out_cap == 0) ? 64 : *out_cap * 2;
        while (cap < *out_len + need + 1) cap *= 2;
        char* p = (char*)realloc(*out, cap);
        if (!p) return -1;
        *out = p; *out_cap = cap;
    }
    char* dst = *out + *out_len;
    int needs_quotes = (*arg == '\0') || strpbrk(arg, " \t\n\v\"") != NULL;
    if (needs_quotes) *dst++ = '"';

    size_t backslashes = 0;
    for (const char* s = arg; *s; s++) {
        if (*s == '\\') {
            backslashes++;
        } else if (*s == '"') {
            for (size_t i = 0; i < 2 * backslashes + 1; i++) *dst++ = '\\';
            *dst++ = '"';
            backslashes = 0;
        } else {
            for (size_t i = 0; i < backslashes; i++) *dst++ = '\\';
            backslashes = 0;
            *dst++ = *s;
        }
    }
    if (needs_quotes) {
        for (size_t i = 0; i < 2 * backslashes; i++) *dst++ = '\\';
        *dst++ = '"';
    } else {
        for (size_t i = 0; i < backslashes; i++) *dst++ = '\\';
    }
    *out_len = dst - *out;
    (*out)[*out_len] = '\0';
    return 0;
}

static char* build_command_line(char** argv) {
    char* out = NULL;
    size_t len = 0, cap = 0;
    for (size_t i = 0; argv[i]; i++) {
        if (i > 0) {
            if (len + 2 > cap) {
                cap = cap == 0 ? 64 : cap * 2;
                out = (char*)realloc(out, cap);
                if (!out) return NULL;
            }
            out[len++] = ' ';
            out[len] = '\0';
        }
        if (append_quoted(&out, &len, &cap, argv[i]) != 0) {
            free(out);
            return NULL;
        }
    }
    return out ? out : strdup("");
}

/* Build an env block: "K1=V1\0K2=V2\0\0" */
static char* build_env_block(char** envp, size_t envc, size_t* out_len) {
    if (envc == 0) {
        /* CreateProcess requires "\0\0" for an empty env block. */
        char* b = (char*)malloc(2);
        if (!b) return NULL;
        b[0] = '\0'; b[1] = '\0';
        *out_len = 2;
        return b;
    }
    size_t total = 1; /* trailing NUL */
    for (size_t i = 0; i < envc; i++) total += strlen(envp[i]) + 1;
    char* b = (char*)malloc(total);
    if (!b) return NULL;
    size_t pos = 0;
    for (size_t i = 0; i < envc; i++) {
        size_t n = strlen(envp[i]);
        memcpy(b + pos, envp[i], n);
        b[pos + n] = '\0';
        pos += n + 1;
    }
    b[pos] = '\0';
    *out_len = pos + 1;
    return b;
}

static int make_pipe_pair(HANDLE* read_h, HANDLE* write_h, int read_inheritable, int write_inheritable) {
    SECURITY_ATTRIBUTES sa = {0};
    sa.nLength = sizeof(sa);
    sa.bInheritHandle = TRUE;
    if (!CreatePipe(read_h, write_h, &sa, 0)) return -1;
    /* Only the end the child should inherit stays inheritable. */
    SetHandleInformation(read_inheritable ? *write_h : *read_h, HANDLE_FLAG_INHERIT, 0);
    return 0;
}

int __flang_proc_spawn(
    const char* prog,
    const uintptr_t* argv, size_t argc,
    const uintptr_t* envp, size_t envc,
    const char* cwd, int32_t has_cwd,
    int32_t stdin_mode, int32_t stdout_mode, int32_t stderr_mode,
    uintptr_t* out_handle,
    int32_t* out_stdin_fd, int32_t* out_stdout_fd, int32_t* out_stderr_fd,
    int32_t* out_err
) {
    (void)prog; /* argv[0] is the program; Windows pulls it from the command line */
    *out_handle = 0;
    *out_stdin_fd = -1; *out_stdout_fd = -1; *out_stderr_fd = -1;
    if (argc == 0) { *out_err = PROC_INVALID_ARGUMENT; return R_ERR; }

    char** argv_z = materialize_argv(argv, argc);
    char** envp_z = materialize_argv(envp, envc);
    if (!argv_z || !envp_z) {
        free(argv_z); free(envp_z);
        *out_err = PROC_IO_ERROR; return R_ERR;
    }

    char* cmdline = build_command_line(argv_z);
    size_t env_len = 0;
    char* env_block = build_env_block(envp_z, envc, &env_len);
    if (!cmdline || !env_block) {
        free(argv_z); free(envp_z); free(cmdline); free(env_block);
        *out_err = PROC_IO_ERROR; return R_ERR;
    }

    HANDLE child_stdin_r = NULL, child_stdin_w = NULL;
    HANDLE child_stdout_r = NULL, child_stdout_w = NULL;
    HANDLE child_stderr_r = NULL, child_stderr_w = NULL;
    /* Track each NUL handle separately. CreateProcess inherits but does not
     * take ownership — the parent must close all three on success and on
     * failure. Sharing a single tracking variable used to leak the stdout
     * and stderr NUL handles when their modes were STDIO_NULL. */
    HANDLE null_in_h = INVALID_HANDLE_VALUE;
    HANDLE null_out_h = INVALID_HANDLE_VALUE;
    HANDLE null_err_h = INVALID_HANDLE_VALUE;

    HANDLE in_h = INVALID_HANDLE_VALUE;
    HANDLE out_h = INVALID_HANDLE_VALUE;
    HANDLE err_h = INVALID_HANDLE_VALUE;

    SECURITY_ATTRIBUTES sa_inherit = {0};
    sa_inherit.nLength = sizeof(sa_inherit);
    sa_inherit.bInheritHandle = TRUE;

    int rc = R_OK;

    switch (stdin_mode) {
        case STDIO_INHERIT: in_h = GetStdHandle(STD_INPUT_HANDLE); break;
        case STDIO_NULL:
            null_in_h = CreateFileA("NUL", GENERIC_READ, FILE_SHARE_READ, &sa_inherit, OPEN_EXISTING, 0, NULL);
            in_h = null_in_h;
            break;
        case STDIO_PIPE:
            if (make_pipe_pair(&child_stdin_r, &child_stdin_w, 1, 0) != 0) goto fail_pipe;
            in_h = child_stdin_r;
            break;
    }
    switch (stdout_mode) {
        case STDIO_INHERIT: out_h = GetStdHandle(STD_OUTPUT_HANDLE); break;
        case STDIO_NULL:
            null_out_h = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_WRITE, &sa_inherit, OPEN_EXISTING, 0, NULL);
            out_h = null_out_h;
            break;
        case STDIO_PIPE:
            if (make_pipe_pair(&child_stdout_r, &child_stdout_w, 0, 1) != 0) goto fail_pipe;
            out_h = child_stdout_w;
            break;
    }
    switch (stderr_mode) {
        case STDIO_INHERIT: err_h = GetStdHandle(STD_ERROR_HANDLE); break;
        case STDIO_NULL:
            null_err_h = CreateFileA("NUL", GENERIC_WRITE, FILE_SHARE_WRITE, &sa_inherit, OPEN_EXISTING, 0, NULL);
            err_h = null_err_h;
            break;
        case STDIO_PIPE:
            if (make_pipe_pair(&child_stderr_r, &child_stderr_w, 0, 1) != 0) goto fail_pipe;
            err_h = child_stderr_w;
            break;
    }

    STARTUPINFOA si = {0};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_h;
    si.hStdOutput = out_h;
    si.hStdError = err_h;

    PROCESS_INFORMATION pi = {0};
    BOOL ok = CreateProcessA(
        NULL,                    /* lpApplicationName — let argv[0] do the work via search */
        cmdline,
        NULL, NULL,
        TRUE,
        0,
        env_block,
        has_cwd ? cwd : NULL,
        &si,
        &pi
    );
    if (!ok) {
        *out_err = proc_err_from_win32(GetLastError());
        rc = R_ERR;
        goto cleanup;
    }

    CloseHandle(pi.hThread);
    *out_handle = (uintptr_t)pi.hProcess;

    /* Convert our pipe ends to CRT fds for read/write reuse. */
    if (stdin_mode == STDIO_PIPE) {
        *out_stdin_fd = _open_osfhandle((intptr_t)child_stdin_w, 0);
        child_stdin_w = NULL;
    }
    if (stdout_mode == STDIO_PIPE) {
        *out_stdout_fd = _open_osfhandle((intptr_t)child_stdout_r, _O_RDONLY);
        child_stdout_r = NULL;
    }
    if (stderr_mode == STDIO_PIPE) {
        *out_stderr_fd = _open_osfhandle((intptr_t)child_stderr_r, _O_RDONLY);
        child_stderr_r = NULL;
    }

cleanup:
    /* Close the child-side ends of any pipes we created. */
    if (child_stdin_r) CloseHandle(child_stdin_r);
    if (child_stdout_w) CloseHandle(child_stdout_w);
    if (child_stderr_w) CloseHandle(child_stderr_w);
    /* Close other ends that were left over (only on failure paths). */
    if (child_stdin_w && rc != R_OK) CloseHandle(child_stdin_w);
    if (child_stdout_r && rc != R_OK) CloseHandle(child_stdout_r);
    if (child_stderr_r && rc != R_OK) CloseHandle(child_stderr_r);
    if (null_in_h != INVALID_HANDLE_VALUE) CloseHandle(null_in_h);
    if (null_out_h != INVALID_HANDLE_VALUE) CloseHandle(null_out_h);
    if (null_err_h != INVALID_HANDLE_VALUE) CloseHandle(null_err_h);
    free(argv_z); free(envp_z); free(cmdline); free(env_block);
    return rc;

fail_pipe:
    *out_err = PROC_IO_ERROR;
    rc = R_ERR;
    goto cleanup;
}

int __flang_proc_wait(uintptr_t handle, int32_t* out_exit, int32_t* out_err) {
    HANDLE h = (HANDLE)handle;
    DWORD r = WaitForSingleObject(h, INFINITE);
    if (r != WAIT_OBJECT_0) {
        *out_err = proc_err_from_win32(GetLastError());
        return R_ERR;
    }
    DWORD code = 0;
    if (!GetExitCodeProcess(h, &code)) {
        *out_err = proc_err_from_win32(GetLastError());
        return R_ERR;
    }
    *out_exit = (int32_t)code;
    return R_OK;
}

int __flang_proc_kill(uintptr_t handle, int32_t* out_err) {
    if (!TerminateProcess((HANDLE)handle, 1)) {
        *out_err = proc_err_from_win32(GetLastError());
        return R_ERR;
    }
    return R_OK;
}

void __flang_proc_release(uintptr_t handle) {
    CloseHandle((HANDLE)handle);
}

intptr_t __flang_proc_read(int32_t fd, uint8_t* buf, size_t cap) {
    if (fd < 0) return 0;
    return _read(fd, buf, (unsigned)cap);
}

intptr_t __flang_proc_write(int32_t fd, const uint8_t* buf, size_t len) {
    if (fd < 0) return -1;
    return _write(fd, buf, (unsigned)len);
}

void __flang_proc_close_fd(int32_t fd) {
    if (fd >= 0) _close(fd);
}

size_t __flang_proc_env_count(void) {
    size_t n = 0;
    if (!environ) return 0;
    while (environ[n]) n++;
    return n;
}

const char* __flang_proc_env_at(size_t i) {
    if (!environ) return NULL;
    for (size_t k = 0; k <= i; k++) {
        if (!environ[k]) return NULL;
        if (k == i) return environ[k];
    }
    return NULL;
}

#else  /* POSIX */

#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <signal.h>
#include <spawn.h>

extern char** environ;

static int dup_to_fd(int src, int target) {
    if (src == target) return 0;
    if (dup2(src, target) < 0) return -1;
    close(src);
    return 0;
}

int __flang_proc_spawn(
    const char* prog,
    const uintptr_t* argv, size_t argc,
    const uintptr_t* envp, size_t envc,
    const char* cwd, int32_t has_cwd,
    int32_t stdin_mode, int32_t stdout_mode, int32_t stderr_mode,
    uintptr_t* out_handle,
    int32_t* out_stdin_fd, int32_t* out_stdout_fd, int32_t* out_stderr_fd,
    int32_t* out_err
) {
    *out_handle = 0;
    *out_stdin_fd = -1; *out_stdout_fd = -1; *out_stderr_fd = -1;
    if (argc == 0 || !prog) { *out_err = PROC_INVALID_ARGUMENT; return R_ERR; }

    char** argv_z = materialize_argv(argv, argc);
    char** envp_z = materialize_argv(envp, envc);
    if (!argv_z || !envp_z) {
        free(argv_z); free(envp_z);
        *out_err = PROC_IO_ERROR; return R_ERR;
    }

    int stdin_pipe[2] = {-1, -1};
    int stdout_pipe[2] = {-1, -1};
    int stderr_pipe[2] = {-1, -1};

    if (stdin_mode == STDIO_PIPE && pipe(stdin_pipe) < 0) goto fail_pipe;
    if (stdout_mode == STDIO_PIPE && pipe(stdout_pipe) < 0) goto fail_pipe;
    if (stderr_mode == STDIO_PIPE && pipe(stderr_pipe) < 0) goto fail_pipe;

    pid_t pid = fork();
    if (pid < 0) {
        *out_err = proc_err_from_errno(errno);
        goto fail_close_all;
    }

    if (pid == 0) {
        /* Child */
        if (has_cwd && cwd && chdir(cwd) != 0) _exit(127);

        int devnull = -1;
        if (stdin_mode == STDIO_NULL || stdout_mode == STDIO_NULL || stderr_mode == STDIO_NULL) {
            devnull = open("/dev/null", O_RDWR);
            if (devnull < 0) _exit(127);
        }

        switch (stdin_mode) {
            case STDIO_PIPE:
                close(stdin_pipe[1]);
                if (dup_to_fd(stdin_pipe[0], 0) < 0) _exit(127);
                break;
            case STDIO_NULL:
                if (dup2(devnull, 0) < 0) _exit(127);
                break;
        }
        switch (stdout_mode) {
            case STDIO_PIPE:
                close(stdout_pipe[0]);
                if (dup_to_fd(stdout_pipe[1], 1) < 0) _exit(127);
                break;
            case STDIO_NULL:
                if (dup2(devnull, 1) < 0) _exit(127);
                break;
        }
        switch (stderr_mode) {
            case STDIO_PIPE:
                close(stderr_pipe[0]);
                if (dup_to_fd(stderr_pipe[1], 2) < 0) _exit(127);
                break;
            case STDIO_NULL:
                if (dup2(devnull, 2) < 0) _exit(127);
                break;
        }
        if (devnull >= 0) close(devnull);

        /* execvpe is a glibc extension. On macOS / BSD we point `environ` at
         * our envp before calling execvp — safe because we are in the
         * post-fork child and nothing else in this process will read environ
         * before the exec. */
#if defined(__linux__) && defined(__GLIBC__)
        execvpe(prog, argv_z, envp_z);
#else
        environ = envp_z;
        execvp(prog, argv_z);
#endif
        _exit(127);
    }

    /* Parent */
    if (stdin_mode == STDIO_PIPE) {
        close(stdin_pipe[0]); stdin_pipe[0] = -1;
        *out_stdin_fd = stdin_pipe[1]; stdin_pipe[1] = -1;
    }
    if (stdout_mode == STDIO_PIPE) {
        close(stdout_pipe[1]); stdout_pipe[1] = -1;
        *out_stdout_fd = stdout_pipe[0]; stdout_pipe[0] = -1;
    }
    if (stderr_mode == STDIO_PIPE) {
        close(stderr_pipe[1]); stderr_pipe[1] = -1;
        *out_stderr_fd = stderr_pipe[0]; stderr_pipe[0] = -1;
    }
    *out_handle = (uintptr_t)pid;
    free(argv_z); free(envp_z);
    return R_OK;

fail_pipe:
    *out_err = PROC_IO_ERROR;
fail_close_all:
    if (stdin_pipe[0] >= 0) close(stdin_pipe[0]);
    if (stdin_pipe[1] >= 0) close(stdin_pipe[1]);
    if (stdout_pipe[0] >= 0) close(stdout_pipe[0]);
    if (stdout_pipe[1] >= 0) close(stdout_pipe[1]);
    if (stderr_pipe[0] >= 0) close(stderr_pipe[0]);
    if (stderr_pipe[1] >= 0) close(stderr_pipe[1]);
    free(argv_z); free(envp_z);
    return R_ERR;
}

int __flang_proc_wait(uintptr_t handle, int32_t* out_exit, int32_t* out_err) {
    pid_t pid = (pid_t)handle;
    int status = 0;
    for (;;) {
        pid_t r = waitpid(pid, &status, 0);
        if (r == pid) break;
        if (r < 0 && errno == EINTR) continue;
        if (r < 0) {
            *out_err = proc_err_from_errno(errno);
            return R_ERR;
        }
    }
    if (WIFEXITED(status)) *out_exit = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) *out_exit = 128 + WTERMSIG(status);
    else *out_exit = -1;
    return R_OK;
}

int __flang_proc_kill(uintptr_t handle, int32_t* out_err) {
    if (kill((pid_t)handle, SIGKILL) != 0) {
        *out_err = proc_err_from_errno(errno);
        return R_ERR;
    }
    return R_OK;
}

void __flang_proc_release(uintptr_t handle) {
    (void)handle;
    /* Nothing to free on POSIX — wait() reaps the zombie. */
}

ssize_t __flang_proc_read(int32_t fd, uint8_t* buf, size_t cap) {
    if (fd < 0) return 0;
    for (;;) {
        ssize_t n = read(fd, buf, cap);
        if (n < 0 && errno == EINTR) continue;
        return n;
    }
}

ssize_t __flang_proc_write(int32_t fd, const uint8_t* buf, size_t len) {
    if (fd < 0) return -1;
    for (;;) {
        ssize_t n = write(fd, buf, len);
        if (n < 0 && errno == EINTR) continue;
        return n;
    }
}

void __flang_proc_close_fd(int32_t fd) {
    if (fd >= 0) close(fd);
}

size_t __flang_proc_env_count(void) {
    size_t n = 0;
    if (!environ) return 0;
    while (environ[n]) n++;
    return n;
}

const char* __flang_proc_env_at(size_t i) {
    if (!environ) return NULL;
    for (size_t k = 0; k <= i; k++) {
        if (!environ[k]) return NULL;
        if (k == i) return environ[k];
    }
    return NULL;
}

#endif
