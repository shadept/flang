/* std.time.clock - the process's two clocks.
 *
 * __flang_monotonic_ns: nanoseconds since an unspecified epoch, stable for
 * the lifetime of the process. Not wall-clock time; for intervals only.
 *
 * __flang_realtime_ticks: wall-clock time as 100 ns ticks since the Unix
 * epoch (1970-01-01T00:00:00Z), the unit of std.time's Instant.
 */

#include <stdint.h>

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

/* QueryPerformanceFrequency is fixed for the lifetime of the system
 * per MSDN - cache it on first call to avoid a syscall per tick. */
static LARGE_INTEGER __flang_qpc_freq = {0};

uint64_t __flang_monotonic_ns(void) {
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    if (__flang_qpc_freq.QuadPart == 0) {
        QueryPerformanceFrequency(&__flang_qpc_freq);
    }
    /* Split the multiply to keep the conversion from overflowing on
     * long-running processes: at QPC frequencies in the 1e7 range,
     * a naive `ticks * 1e9` would wrap after ~10 minutes. */
    uint64_t freq = (uint64_t)__flang_qpc_freq.QuadPart;
    uint64_t ticks = (uint64_t)now.QuadPart;
    uint64_t seconds = ticks / freq;
    uint64_t remainder = ticks % freq;
    return seconds * 1000000000ULL + (remainder * 1000000000ULL) / freq;
}

/* FILETIME counts 100 ns ticks since 1601-01-01; this many separate
 * that from the Unix epoch. */
#define FLANG_FILETIME_UNIX_EPOCH 116444736000000000LL

int64_t __flang_realtime_ticks(void) {
    FILETIME ft;
    GetSystemTimePreciseAsFileTime(&ft);
    int64_t t = ((int64_t)ft.dwHighDateTime << 32) | (int64_t)ft.dwLowDateTime;
    return t - FLANG_FILETIME_UNIX_EPOCH;
}

#else /* POSIX */

#include <time.h>

uint64_t __flang_monotonic_ns(void) {
    struct timespec ts;
    /* CLOCK_MONOTONIC is guaranteed not to jump (no NTP adjustments,
     * no daylight-saving). On Linux this is implemented via the vDSO
     * and is effectively a few cycles; on macOS it routes through
     * mach_absolute_time. */
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

int64_t __flang_realtime_ticks(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (int64_t)ts.tv_sec * 10000000LL + (int64_t)ts.tv_nsec / 100;
}

#endif
