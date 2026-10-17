/* std.time.zone - the time zone database, behind three calls.
 *
 *   __flang_tz_open(name, len, &handle)  resolve an IANA name, or the
 *                                         system zone when len == 0
 *   __flang_tz_offset(handle, unix_sec)  UTC offset in seconds at an instant
 *   __flang_tz_name(handle, &len)        the zone's IANA name
 *
 * open returns 0 on success, 1 for an unknown zone, 2 when no zone data is
 * available on this system. Handles index a process-lifetime registry: a
 * name opened twice yields the same handle, and nothing is ever freed, so
 * a handle stays valid and its name pointer stable until exit.
 *
 * POSIX reads TZif files (RFC 8536) from $TZDIR or /usr/share/zoneinfo; the
 * system zone is $TZ (a name, a path, or a POSIX TZ rule string), else
 * /etc/localtime, else UTC. Instants past a file's last transition follow
 * its footer rule. Windows asks the ICU that ships with Windows 10 1903+
 * (icu.dll), loaded on first use.
 *
 * Single-threaded, like the rest of the FLang runtime.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define FLANG_TZ_OK 0
#define FLANG_TZ_UNKNOWN 1
#define FLANG_TZ_UNAVAILABLE 2
#define FLANG_TZ_NAME_MAX 255

typedef struct {
    char* name;
    size_t name_len;
#ifdef _WIN32
    void* cal;
#else
    int64_t* times;
    uint8_t* idx;
    int32_t* offs;
    int32_t timecnt;
    int32_t typecnt;
    int has_rule;
    struct flang_tz_rule {
        int32_t std_off;
        int32_t dst_off;
        int has_dst;
        struct flang_tz_date {
            int kind; /* 0: Jn, 1: n, 2: Mm.w.d */
            int n, m, w, d;
            int32_t time;
        } start, end;
    } rule;
#endif
} flang_tz;

static flang_tz* flang_tz_zones = NULL;
static int32_t flang_tz_count = 0;
static int32_t flang_tz_cap = 0;
static int32_t flang_tz_system = -1;

static int32_t flang_tz_add(flang_tz* z) {
    if (flang_tz_count == flang_tz_cap) {
        int32_t cap = flang_tz_cap == 0 ? 8 : flang_tz_cap * 2;
        flang_tz* grown = (flang_tz*)realloc(flang_tz_zones, (size_t)cap * sizeof(flang_tz));
        if (!grown) {
            return -1;
        }
        flang_tz_zones = grown;
        flang_tz_cap = cap;
    }
    flang_tz_zones[flang_tz_count] = *z;
    return flang_tz_count++;
}

static int32_t flang_tz_find(const char* name, size_t len) {
    for (int32_t i = 0; i < flang_tz_count; i++) {
        flang_tz* z = &flang_tz_zones[i];
        if (z->name_len == len && memcmp(z->name, name, len) == 0) {
            return i;
        }
    }
    return -1;
}

static char* flang_tz_strdup(const char* s, size_t len) {
    char* out = (char*)malloc(len + 1);
    if (out) {
        memcpy(out, s, len);
        out[len] = 0;
    }
    return out;
}

/* An IANA name is relative and stays inside the database: no leading '/',
 * no '..' component, ASCII only. */
static int flang_tz_valid_name(const uint8_t* name, size_t len) {
    if (len == 0 || len > FLANG_TZ_NAME_MAX || name[0] == '/') {
        return 0;
    }
    for (size_t i = 0; i < len; i++) {
        if (name[i] < 0x21 || name[i] > 0x7E || name[i] == '\\') {
            return 0;
        }
        if (name[i] == '.' && i + 1 < len && name[i + 1] == '.') {
            return 0;
        }
    }
    return 1;
}

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

/* The ICU C API, as exported unversioned by Windows' icu.dll. */
typedef void* (*flang_ucal_open_fn)(const uint16_t*, int32_t, const char*, int, int*);
typedef void (*flang_ucal_set_millis_fn)(void*, double, int*);
typedef int32_t (*flang_ucal_get_fn)(const void*, int, int*);
typedef int32_t (*flang_ucal_canonical_fn)(const uint16_t*, int32_t, uint16_t*, int32_t, int8_t*, int*);
typedef int32_t (*flang_ucal_default_fn)(uint16_t*, int32_t, int*);

#define FLANG_UCAL_GREGORIAN 1
#define FLANG_UCAL_ZONE_OFFSET 15
#define FLANG_UCAL_DST_OFFSET 16
#define FLANG_U_FAILURE(s) ((s) > 0)

static int flang_icu_state = 0; /* 0 untried, 1 loaded, -1 missing */
static flang_ucal_open_fn flang_ucal_open;
static flang_ucal_set_millis_fn flang_ucal_set_millis;
static flang_ucal_get_fn flang_ucal_get;
static flang_ucal_canonical_fn flang_ucal_canonical;
static flang_ucal_default_fn flang_ucal_default;

static int flang_icu_load(void) {
    if (flang_icu_state != 0) {
        return flang_icu_state == 1;
    }
    flang_icu_state = -1;
    HMODULE icu = LoadLibraryA("icu.dll");
    if (!icu) {
        return 0;
    }
    flang_ucal_open = (flang_ucal_open_fn)(void*)GetProcAddress(icu, "ucal_open");
    flang_ucal_set_millis = (flang_ucal_set_millis_fn)(void*)GetProcAddress(icu, "ucal_setMillis");
    flang_ucal_get = (flang_ucal_get_fn)(void*)GetProcAddress(icu, "ucal_get");
    flang_ucal_canonical = (flang_ucal_canonical_fn)(void*)GetProcAddress(icu, "ucal_getCanonicalTimeZoneID");
    flang_ucal_default = (flang_ucal_default_fn)(void*)GetProcAddress(icu, "ucal_getDefaultTimeZone");
    if (!flang_ucal_open || !flang_ucal_set_millis || !flang_ucal_get || !flang_ucal_canonical ||
        !flang_ucal_default) {
        return 0;
    }
    flang_icu_state = 1;
    return 1;
}

/* ICU also accepts the 3-letter IDs of old Java (BST is Asia/Dhaka, IST Asia/Kolkata), which the
   IANA database lacks; refusing them keeps a name resolving the same on every platform. */
static int flang_tz_is_java_legacy(const char* name, size_t len) {
    static const char* const ids[] = {
        "ACT", "AET", "AGT", "ART", "AST", "BET", "BST", "CAT", "CNT", "CST", "CTT", "EAT", "ECT",
        "IET", "IST", "JST", "MIT", "NET", "NST", "PLT", "PNT", "PRT", "PST", "SST", "VST",
    };
    if (len != 3) {
        return 0;
    }
    for (size_t i = 0; i < sizeof ids / sizeof ids[0]; i++) {
        if (memcmp(name, ids[i], 3) == 0) {
            return 1;
        }
    }
    return 0;
}

static int32_t flang_tz_open_icu(const char* name, size_t len, int32_t* out_handle) {
    if (flang_tz_is_java_legacy(name, len)) {
        return FLANG_TZ_UNKNOWN;
    }
    uint16_t wide[FLANG_TZ_NAME_MAX + 1];
    for (size_t i = 0; i < len; i++) {
        wide[i] = (uint16_t)(uint8_t)name[i];
    }
    uint16_t canonical[FLANG_TZ_NAME_MAX + 1];
    int8_t is_system = 0;
    int status = 0;
    flang_ucal_canonical(wide, (int32_t)len, canonical, FLANG_TZ_NAME_MAX, &is_system, &status);
    if (FLANG_U_FAILURE(status)) {
        return FLANG_TZ_UNKNOWN;
    }
    status = 0;
    void* cal = flang_ucal_open(wide, (int32_t)len, NULL, FLANG_UCAL_GREGORIAN, &status);
    if (FLANG_U_FAILURE(status) || !cal) {
        return FLANG_TZ_UNKNOWN;
    }
    flang_tz z;
    z.name = flang_tz_strdup(name, len);
    z.name_len = len;
    z.cal = cal;
    int32_t h = z.name ? flang_tz_add(&z) : -1;
    if (h < 0) {
        return FLANG_TZ_UNAVAILABLE;
    }
    *out_handle = h;
    return FLANG_TZ_OK;
}

int32_t __flang_tz_open(const uint8_t* name, size_t len, int32_t* out_handle) {
    if (!flang_icu_load()) {
        return FLANG_TZ_UNAVAILABLE;
    }
    if (len == 0) {
        if (flang_tz_system >= 0) {
            *out_handle = flang_tz_system;
            return FLANG_TZ_OK;
        }
        uint16_t wide[FLANG_TZ_NAME_MAX + 1];
        int status = 0;
        int32_t n = flang_ucal_default(wide, FLANG_TZ_NAME_MAX, &status);
        if (FLANG_U_FAILURE(status) || n <= 0 || n > FLANG_TZ_NAME_MAX) {
            return FLANG_TZ_UNAVAILABLE;
        }
        char ascii[FLANG_TZ_NAME_MAX + 1];
        for (int32_t i = 0; i < n; i++) {
            ascii[i] = wide[i] < 0x80 ? (char)wide[i] : '?';
        }
        int32_t rc = __flang_tz_open((const uint8_t*)ascii, (size_t)n, out_handle);
        if (rc == FLANG_TZ_OK) {
            flang_tz_system = *out_handle;
        }
        return rc;
    }
    if (!flang_tz_valid_name(name, len)) {
        return FLANG_TZ_UNKNOWN;
    }
    int32_t found = flang_tz_find((const char*)name, len);
    if (found >= 0) {
        *out_handle = found;
        return FLANG_TZ_OK;
    }
    return flang_tz_open_icu((const char*)name, len, out_handle);
}

int32_t __flang_tz_offset(int32_t handle, int64_t unix_seconds) {
    flang_tz* z = &flang_tz_zones[handle];
    int status = 0;
    flang_ucal_set_millis(z->cal, (double)unix_seconds * 1000.0, &status);
    int32_t zone = flang_ucal_get(z->cal, FLANG_UCAL_ZONE_OFFSET, &status);
    int32_t dst = flang_ucal_get(z->cal, FLANG_UCAL_DST_OFFSET, &status);
    if (FLANG_U_FAILURE(status)) {
        return 0;
    }
    return (zone + dst) / 1000;
}

#else /* POSIX */

#include <stdio.h>
#include <unistd.h>

static int64_t flang_tz_days_from_civil(int64_t y, int64_t m, int64_t d) {
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    int64_t yoe = y - era * 400;
    int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

static int64_t flang_tz_year_of(int64_t unix_seconds) {
    int64_t z = (unix_seconds >= 0 ? unix_seconds : unix_seconds - 86399) / 86400 + 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    int64_t doe = z - era * 146097;
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    return yoe + era * 400 + (mp >= 10);
}

static int flang_tz_leap(int64_t y) {
    return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
}

/* --- POSIX TZ rule strings, e.g. "CET-1CEST,M3.5.0,M10.5.0/3" --- */

static const char* flang_tz_parse_name(const char* p) {
    if (*p == '<') {
        while (*p && *p != '>') {
            p++;
        }
        return *p == '>' ? p + 1 : NULL;
    }
    const char* start = p;
    while ((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')) {
        p++;
    }
    return p - start >= 3 ? p : NULL;
}

static int flang_tz_parse_num(const char** pp, int max_digits, int* out) {
    const char* p = *pp;
    int n = 0, digits = 0;
    while (*p >= '0' && *p <= '9' && digits < max_digits) {
        n = n * 10 + (*p - '0');
        p++;
        digits++;
    }
    if (digits == 0) {
        return 0;
    }
    *pp = p;
    *out = n;
    return 1;
}

/* [+-]hh[:mm[:ss]] in seconds; hours up to 167 for the v3 time extension. */
static const char* flang_tz_parse_hms(const char* p, int32_t* out) {
    int sign = 1, h = 0, m = 0, s = 0;
    if (*p == '+' || *p == '-') {
        sign = *p == '-' ? -1 : 1;
        p++;
    }
    if (!flang_tz_parse_num(&p, 3, &h)) {
        return NULL;
    }
    if (*p == ':') {
        p++;
        if (!flang_tz_parse_num(&p, 2, &m)) {
            return NULL;
        }
        if (*p == ':') {
            p++;
            if (!flang_tz_parse_num(&p, 2, &s)) {
                return NULL;
            }
        }
    }
    *out = sign * (h * 3600 + m * 60 + s);
    return p;
}

static const char* flang_tz_parse_date(const char* p, struct flang_tz_date* d) {
    d->time = 7200;
    if (*p == 'J') {
        p++;
        d->kind = 0;
        if (!flang_tz_parse_num(&p, 3, &d->n)) {
            return NULL;
        }
    } else if (*p == 'M') {
        p++;
        d->kind = 2;
        if (!flang_tz_parse_num(&p, 2, &d->m) || *p++ != '.') {
            return NULL;
        }
        if (!flang_tz_parse_num(&p, 1, &d->w) || *p++ != '.') {
            return NULL;
        }
        if (!flang_tz_parse_num(&p, 1, &d->d)) {
            return NULL;
        }
    } else {
        d->kind = 1;
        if (!flang_tz_parse_num(&p, 3, &d->n)) {
            return NULL;
        }
    }
    if (*p == '/') {
        p = flang_tz_parse_hms(p + 1, &d->time);
    }
    return p;
}


static int flang_tz_date_in_range(const struct flang_tz_date* d) {
    switch (d->kind) {
    case 0: return d->n >= 1 && d->n <= 365;
    case 1: return d->n >= 0 && d->n <= 365;
    default: return d->m >= 1 && d->m <= 12 && d->w >= 1 && d->w <= 5 && d->d >= 0 && d->d <= 6;
    }
}

static int flang_tz_parse_rule_dates(const char* p, struct flang_tz_rule* r) {
    p = flang_tz_parse_date(p, &r->start);
    if (!p || *p != ',' || !flang_tz_date_in_range(&r->start)) {
        return 0;
    }
    p = flang_tz_parse_date(p + 1, &r->end);
    return p != NULL && flang_tz_date_in_range(&r->end);
}

static int flang_tz_parse_rule(const char* p, struct flang_tz_rule* r) {
    memset(r, 0, sizeof *r);
    int32_t posix_off;
    p = flang_tz_parse_name(p);
    if (!p || !(p = flang_tz_parse_hms(p, &posix_off))) {
        return 0;
    }
    /* POSIX offsets count west of Greenwich; ours count east. */
    r->std_off = -posix_off;
    if (*p == 0 || *p == '\n') {
        return 1;
    }
    p = flang_tz_parse_name(p);
    if (!p) {
        return 0;
    }
    r->has_dst = 1;
    r->dst_off = r->std_off + 3600;
    if (*p != ',' && *p != 0 && *p != '\n') {
        if (!(p = flang_tz_parse_hms(p, &posix_off))) {
            return 0;
        }
        r->dst_off = -posix_off;
    }
    if (*p != ',') {
        /* A DST name without dates takes the POSIX default, US rules since 2007. */
        return flang_tz_parse_rule_dates("M3.2.0,M11.1.0", r);
    }
    return flang_tz_parse_rule_dates(p + 1, r);
}

static const int flang_tz_month_days[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};

/* Seconds since the epoch, on the rule's local clock, of a transition date in `year`. */
static int64_t flang_tz_rule_local(int64_t year, const struct flang_tz_date* d) {
    int64_t jan1 = flang_tz_days_from_civil(year, 1, 1);
    int64_t day;
    if (d->kind == 0) {
        day = d->n - 1 + (flang_tz_leap(year) && d->n >= 60);
    } else if (d->kind == 1) {
        day = d->n;
    } else {
        int64_t first = flang_tz_days_from_civil(year, d->m, 1);
        int64_t first_wday = ((first % 7) + 7 + 4) % 7; /* 1970-01-01 was a Thursday */
        int64_t dim = flang_tz_month_days[d->m - 1] + (d->m == 2 && flang_tz_leap(year));
        int64_t mday = (d->d - first_wday + 7) % 7 + (int64_t)(d->w - 1) * 7;
        while (mday >= dim) {
            mday -= 7;
        }
        day = first - jan1 + mday;
    }
    return (jan1 + day) * 86400 + d->time;
}

static int32_t flang_tz_rule_offset(const struct flang_tz_rule* r, int64_t t) {
    if (!r->has_dst) {
        return r->std_off;
    }
    int64_t year = flang_tz_year_of(t + r->std_off);
    int64_t start = flang_tz_rule_local(year, &r->start) - r->std_off;
    int64_t end = flang_tz_rule_local(year, &r->end) - r->dst_off;
    int dst = start < end ? (t >= start && t < end) : !(t >= end && t < start);
    return dst ? r->dst_off : r->std_off;
}

/* --- TZif files (RFC 8536) --- */

static uint32_t flang_tz_be32(const uint8_t* p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int64_t flang_tz_be64(const uint8_t* p) {
    return (int64_t)(((uint64_t)flang_tz_be32(p) << 32) | (uint64_t)flang_tz_be32(p + 4));
}

#define FLANG_TZIF_MAX_COUNT (1u << 20)

typedef struct {
    size_t isutcnt, isstdcnt, leapcnt, timecnt, typecnt, charcnt;
} flang_tzif_counts;

static int flang_tzif_header(const uint8_t* p, size_t avail, flang_tzif_counts* c) {
    if (avail < 44 || memcmp(p, "TZif", 4) != 0) {
        return 0;
    }
    c->isutcnt = flang_tz_be32(p + 20);
    c->isstdcnt = flang_tz_be32(p + 24);
    c->leapcnt = flang_tz_be32(p + 28);
    c->timecnt = flang_tz_be32(p + 32);
    c->typecnt = flang_tz_be32(p + 36);
    c->charcnt = flang_tz_be32(p + 40);
    return c->isutcnt < FLANG_TZIF_MAX_COUNT && c->isstdcnt < FLANG_TZIF_MAX_COUNT &&
           c->leapcnt < FLANG_TZIF_MAX_COUNT && c->timecnt < FLANG_TZIF_MAX_COUNT &&
           c->typecnt < FLANG_TZIF_MAX_COUNT && c->charcnt < FLANG_TZIF_MAX_COUNT;
}

static size_t flang_tzif_body_size(const flang_tzif_counts* c, size_t time_size) {
    return c->timecnt * time_size + c->timecnt + c->typecnt * 6 + c->charcnt +
           c->leapcnt * (time_size + 4) + c->isstdcnt + c->isutcnt;
}

static int flang_tz_load_tzif(const uint8_t* buf, size_t len, flang_tz* z) {
    flang_tzif_counts c;
    if (!flang_tzif_header(buf, len, &c)) {
        return 0;
    }
    const uint8_t* p = buf;
    size_t time_size = 4;
    if (buf[4] >= '2') {
        size_t skip = 44 + flang_tzif_body_size(&c, 4);
        if (skip > len || !flang_tzif_header(buf + skip, len - skip, &c)) {
            return 0;
        }
        p = buf + skip;
        time_size = 8;
    }
    const uint8_t* d = p + 44;
    const uint8_t* end = buf + len;
    size_t body = flang_tzif_body_size(&c, time_size);
    if (c.typecnt == 0 || body > (size_t)(end - d)) {
        return 0;
    }
    z->timecnt = (int32_t)c.timecnt;
    z->typecnt = (int32_t)c.typecnt;
    z->times = (int64_t*)malloc((c.timecnt + 1) * sizeof(int64_t));
    z->idx = (uint8_t*)malloc(c.timecnt + 1);
    z->offs = (int32_t*)malloc(c.typecnt * sizeof(int32_t));
    if (!z->times || !z->idx || !z->offs) {
        return 0;
    }
    for (size_t i = 0; i < c.timecnt; i++) {
        const uint8_t* t = d + i * time_size;
        z->times[i] = time_size == 8 ? flang_tz_be64(t) : (int64_t)(int32_t)flang_tz_be32(t);
    }
    d += c.timecnt * time_size;
    for (size_t i = 0; i < c.timecnt; i++) {
        if (d[i] >= c.typecnt) {
            return 0;
        }
        z->idx[i] = d[i];
    }
    d += c.timecnt;
    for (size_t i = 0; i < c.typecnt; i++) {
        z->offs[i] = (int32_t)flang_tz_be32(d + i * 6);
    }
    d = p + 44 + body;
    if (time_size == 8 && d < end && *d == '\n') {
        char footer[256];
        size_t n = 0;
        d++;
        while (d < end && *d != '\n' && n < sizeof footer - 1) {
            footer[n++] = (char)*d++;
        }
        footer[n] = 0;
        z->has_rule = n > 0 && flang_tz_parse_rule(footer, &z->rule);
    }
    return 1;
}

static void flang_tz_release(flang_tz* z) {
    free(z->times);
    free(z->idx);
    free(z->offs);
    memset(z, 0, sizeof *z);
}

static int flang_tz_load_path(const char* path, flang_tz* z) {
    FILE* f = fopen(path, "rb");
    if (!f) {
        return 0;
    }
    uint8_t* buf = NULL;
    size_t len = 0, cap = 0;
    for (;;) {
        if (len == cap) {
            cap = cap == 0 ? 4096 : cap * 2;
            if (cap > ((size_t)1 << 22)) {
                break;
            }
            uint8_t* grown = (uint8_t*)realloc(buf, cap);
            if (!grown) {
                break;
            }
            buf = grown;
        }
        size_t n = fread(buf + len, 1, cap - len, f);
        if (n == 0) {
            break;
        }
        len += n;
    }
    fclose(f);
    int ok = buf != NULL && flang_tz_load_tzif(buf, len, z);
    free(buf);
    if (!ok) {
        flang_tz_release(z);
    }
    return ok;
}

static const char* flang_tz_dir(void) {
    const char* dir = getenv("TZDIR");
    return dir && *dir ? dir : "/usr/share/zoneinfo";
}

static int32_t flang_tz_register(const char* name, size_t len, flang_tz* z, int32_t* out_handle) {
    if (len > FLANG_TZ_NAME_MAX) {
        len = FLANG_TZ_NAME_MAX;
    }
    z->name = flang_tz_strdup(name, len);
    z->name_len = len;
    int32_t h = z->name ? flang_tz_add(z) : -1;
    if (h < 0) {
        return FLANG_TZ_UNAVAILABLE;
    }
    *out_handle = h;
    return FLANG_TZ_OK;
}

/* The zone name inside a database path: ".../zoneinfo/Europe/Lisbon" -> "Europe/Lisbon". */
static const char* flang_tz_name_in_path(const char* path) {
    const char* hit = strstr(path, "zoneinfo/");
    return hit ? hit + 9 : path;
}

static int32_t flang_tz_open_system(int32_t* out_handle) {
    if (flang_tz_system >= 0) {
        *out_handle = flang_tz_system;
        return FLANG_TZ_OK;
    }
    flang_tz z;
    memset(&z, 0, sizeof z);
    char path[4096];
    const char* name = "UTC";
    int loaded = 0;
    const char* tz = getenv("TZ");
    if (tz && *tz) {
        if (*tz == ':') {
            tz++;
        }
        if (*tz == '/') {
            loaded = flang_tz_load_path(tz, &z);
            name = flang_tz_name_in_path(tz);
        } else if (flang_tz_valid_name((const uint8_t*)tz, strlen(tz))) {
            snprintf(path, sizeof path, "%s/%s", flang_tz_dir(), tz);
            loaded = flang_tz_load_path(path, &z);
            name = tz;
        }
        if (!loaded && flang_tz_parse_rule(tz, &z.rule)) {
            z.has_rule = 1;
            loaded = 1;
            name = tz;
        }
    } else if (!tz) {
        loaded = flang_tz_load_path("/etc/localtime", &z);
        ssize_t n = readlink("/etc/localtime", path, sizeof path - 1);
        if (loaded) {
            name = "localtime";
        }
        if (loaded && n > 0) {
            path[n] = 0;
            name = flang_tz_name_in_path(path);
        }
    }
    if (!loaded) {
        /* No usable zone: UTC, as glibc and musl fall back to. */
        memset(&z, 0, sizeof z);
        z.has_rule = 1;
        name = "UTC";
    }
    int32_t rc = flang_tz_register(name, strlen(name), &z, out_handle);
    if (rc == FLANG_TZ_OK) {
        flang_tz_system = *out_handle;
    }
    return rc;
}

int32_t __flang_tz_open(const uint8_t* name, size_t len, int32_t* out_handle) {
    if (len == 0) {
        return flang_tz_open_system(out_handle);
    }
    if (!flang_tz_valid_name(name, len)) {
        return FLANG_TZ_UNKNOWN;
    }
    int32_t found = flang_tz_find((const char*)name, len);
    if (found >= 0) {
        *out_handle = found;
        return FLANG_TZ_OK;
    }
    const char* dir = flang_tz_dir();
    if (access(dir, F_OK) != 0) {
        return FLANG_TZ_UNAVAILABLE;
    }
    char path[4096];
    snprintf(path, sizeof path, "%s/%.*s", dir, (int)len, (const char*)name);
    flang_tz z;
    memset(&z, 0, sizeof z);
    if (!flang_tz_load_path(path, &z)) {
        return FLANG_TZ_UNKNOWN;
    }
    return flang_tz_register((const char*)name, len, &z, out_handle);
}

int32_t __flang_tz_offset(int32_t handle, int64_t unix_seconds) {
    flang_tz* z = &flang_tz_zones[handle];
    int32_t n = z->timecnt;
    if (n == 0 || unix_seconds >= z->times[n - 1]) {
        if (z->has_rule) {
            return flang_tz_rule_offset(&z->rule, unix_seconds);
        }
        if (n == 0) {
            return z->typecnt > 0 ? z->offs[0] : 0;
        }
        return z->offs[z->idx[n - 1]];
    }
    if (unix_seconds < z->times[0]) {
        return z->offs[0];
    }
    int32_t lo = 0, hi = n - 1;
    while (lo < hi) {
        int32_t mid = lo + (hi - lo + 1) / 2;
        if (z->times[mid] <= unix_seconds) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    return z->offs[z->idx[lo]];
}

#endif

const uint8_t* __flang_tz_name(int32_t handle, size_t* out_len) {
    *out_len = flang_tz_zones[handle].name_len;
    return (const uint8_t*)flang_tz_zones[handle].name;
}
