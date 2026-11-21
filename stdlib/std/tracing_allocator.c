/* std.tracing_allocator - native stack capture and symbol names, the one
 * part of allocation tracing FLang cannot express. `std.test`'s leak ledger
 * uses the same two calls.
 *
 * Symbols come from dbghelp on MSVC and `backtrace_symbols` on glibc/macOS;
 * elsewhere capture returns no frames and a frame names its bare address.
 */

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#if defined(_MSC_VER)
#include <dbghelp.h>
#pragma comment(lib, "dbghelp.lib")
#define FLANG_TRACE_SYMBOLS 1
#endif
#elif defined(__GLIBC__) || defined(__APPLE__)
#include <execinfo.h>
#define FLANG_TRACE_SYMBOLS 1
#endif

/* Return addresses of the calling stack, innermost first, this function
   excluded: at most `max` of them into `frames`, returning how many. */
size_t __flang_trace_capture(size_t *frames, size_t max) {
#if defined(_WIN32)
    return (size_t)CaptureStackBackTrace(1, (DWORD)max, (void **)frames, NULL);
#elif defined(FLANG_TRACE_SYMBOLS)
    void *raw[65];
    int n;
    if (max > 64) {
        max = 64;
    }
    n = backtrace(raw, (int)max + 1);
    if (n <= 1) {
        return 0;
    }
    memcpy(frames, raw + 1, (size_t)(n - 1) * sizeof(void *));
    return (size_t)(n - 1);
#else
    (void)frames;
    (void)max;
    return 0;
#endif
}

/* The symbol at `addr` as text in `buf` (not NUL-terminated), returning its
   length: "name +0xoffset" on MSVC, the `backtrace_symbols` line elsewhere,
   the bare address when nothing resolves it. */
size_t __flang_trace_symbol(size_t addr, unsigned char *buf, size_t cap) {
    char line[600];
    size_t len;
    line[0] = '\0';
#if defined(_WIN32) && defined(FLANG_TRACE_SYMBOLS)
    static int ready = 0;
    char info[sizeof(SYMBOL_INFO) + 512];
    SYMBOL_INFO *sym = (SYMBOL_INFO *)info;
    DWORD64 disp = 0;
    if (!ready) {
        SymSetOptions(SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
        SymInitialize(GetCurrentProcess(), NULL, TRUE);
        ready = 1;
    }
    sym->SizeOfStruct = sizeof(SYMBOL_INFO);
    sym->MaxNameLen = 511;
    if (SymFromAddr(GetCurrentProcess(), (DWORD64)addr, &disp, sym)) {
        snprintf(line, sizeof line, "%s +0x%llx", sym->Name, (unsigned long long)disp);
    }
#elif defined(FLANG_TRACE_SYMBOLS)
    void *at = (void *)addr;
    char **names = backtrace_symbols(&at, 1);
    if (names != NULL) {
        snprintf(line, sizeof line, "%s", names[0]);
        free(names);
    }
#endif
    if (line[0] == '\0') {
        snprintf(line, sizeof line, "%p", (void *)addr);
    }
    len = strlen(line);
    if (len > cap) {
        len = cap;
    }
    memcpy(buf, line, len);
    return len;
}
