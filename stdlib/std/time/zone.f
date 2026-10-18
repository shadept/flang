// std.time.zone - time zones, and the date-time that carries a UTC offset.
//
// A `TimeZone` maps an Instant to its UTC offset: UTC, a fixed offset, or a zone of the system's
// IANA database ("Europe/Lisbon") resolved by `zone(name)`; `system_zone()` is the zone the machine
// is set to. Database zones come from the runtime (zone.c): TZif files on POSIX ($TZDIR or
// /usr/share/zoneinfo), ICU on Windows (icu.dll, Windows 10 1903 and later). A resolved zone lives
// until the process exits, so a TimeZone is a copyable handle with nothing to release.
//
// Converting between the timeline and the wall clock is the zone's job: `i.to_datetime(tz)` reads
// the wall clock at an Instant, `dt.to_instant(tz)` finds the Instant a wall-clock reading names.
//
// `OffsetDateTime` is an Instant together with the offset it was read at (C# DateTimeOffset, chrono
// DateTime<FixedOffset>, an RFC 3339 timestamp). It keeps the offset, not the zone: to move it in
// time and stay in a zone, convert its Instant again.
//
// The parsers that need a zone live here: `parse_zone` for a zone field, the
// `parse_offset_datetime` and `parse_instant` overloads that take a fallback zone or a pattern, and
// `parse_rfc5322`.

import std.format
import std.io.writer
import std.result
import std.string
import std.string_builder
import std.test
import std.time.calendar
import std.time.date
import std.time.datetime
import std.time.duration
import std.time.instant
import std.time.internal.common
import std.time.internal.parse
import std.time.time

#foreign fn __flang_tz_open(name: &u8, len: usize, out_handle: &i32) i32
#foreign fn __flang_tz_offset(handle: i32, unix_seconds: i64) i32
#foreign fn __flang_tz_name(handle: i32, out_len: &usize) &u8

pub type TimeZone = enum {
    Utc
    // Seconds east of UTC, less than a day either way.
    Fixed(i32)
    // A zone of the system database, by runtime handle.
    Named(i32)
}

pub type OffsetDateTime = struct {
    instant: Instant
    // Seconds east of UTC.
    offset: i32
}

// =============================================================================
// TimeZone
// =============================================================================

// A zone always `offset_seconds` east of UTC. InvalidOffset for a day or more either way.
pub fn fixed_zone(offset_seconds: i32) Result(TimeZone, TimeError) {
    if offset_seconds <= -86400 or offset_seconds >= 86400 {
        return Err(TimeError.InvalidOffset)
    }
    return Ok(TimeZone.Fixed(offset_seconds))
}

// The IANA zone `name`, exactly: "Europe/Lisbon", "America/New_York". "UTC" is always Utc, database
// or not. UnknownZone for a name the database lacks; ZoneDataUnavailable when the system has no
// database. To read a zone field in any of its other spellings, use parse_zone.
pub fn zone(name: String) Result(TimeZone, TimeError) {
    if name == "UTC" {
        return Ok(TimeZone.Utc)
    }
    if name.len == 0 {
        return Err(TimeError.UnknownZone)
    }
    return open_zone(name)
}

// Read a zone field. `UTC`, `Z`, `GMT` and `UT`, in any case, are Utc. An offset (`+01:00`,
// `+0100`, `+01`, `-5`), alone or after UTC or GMT (`UTC+1`, `GMT-05:00`), is Fixed, as are the
// North American names RFC 5322 defines: EST, EDT, CST, CDT, MST, MDT, PST, PDT. Anything else goes
// to `zone`, so an abbreviation the IANA database carries (CET, HST) is its zone and an ambiguous
// one (IST, BST) is UnknownZone.
pub fn parse_zone(s: String) Result(TimeZone, TimeError) {
    const is_utc = eq_ignore_ascii_case(s, "UTC") or eq_ignore_ascii_case(s, "Z")
        or eq_ignore_ascii_case(s, "GMT") or eq_ignore_ascii_case(s, "UT")
    if is_utc {
        return Ok(TimeZone.Utc)
    }
    rfc5322_zone(s) match {
        Some(offset) => return fixed_zone(offset)
        None => {}
    }
    let sc = scanner(s)
    const _prefixed = sc.eat_word("UTC") or sc.eat_word("GMT")
    const c = sc.peek()
    if c != '+' and c != '-' {
        return zone(s)
    }
    const offset = sc.scan_loose_offset()?
    if !sc.at_end() {
        return Err(TimeError.BadFormat)
    }
    return fixed_zone(offset)
}

// The zone the system is set to. POSIX reads $TZ (a zone name, a TZif path or a POSIX rule string),
// then /etc/localtime, and falls back to UTC as libc does; Windows asks ICU.
pub fn system_zone() Result(TimeZone, TimeError) {
    return open_zone("")
}

fn open_zone(name: String) Result(TimeZone, TimeError) {
    let handle = 0i32
    const status = __flang_tz_open(name.ptr, name.len, &handle)
    return status match {
        0 => Ok(TimeZone.Named(handle))
        1 => Err(TimeError.UnknownZone)
        else => Err(TimeError.ZoneDataUnavailable)
    }
}

// Seconds east of UTC at `at`.
pub fn offset_at(self: TimeZone, at: Instant) i32 {
    return self match {
        Utc => 0
        Fixed(offset) => offset
        Named(handle) => __flang_tz_offset(handle, at.unix_seconds())
    }
}

pub fn op_eq(a: TimeZone, b: TimeZone) bool {
    return a match {
        Utc => b match { Utc => true, else => false }
        Fixed(x) => b match { Fixed(y) => x == y, else => false }
        Named(x) => b match { Named(y) => x == y, else => false }
    }
}

// `UTC`, `+05:30`, or the database name.
pub fn format(self: TimeZone, w: Writer, spec: String) {
    self match {
        Utc => "UTC".format(w, spec)
        Fixed(offset) => write_offset(w, offset, true)
        Named(handle) => {
            let len = 0usize
            const ptr = __flang_tz_name(handle, &len)
            const name = slice_from_raw_parts(ptr, len) as String
            name.format(w, spec)
        }
    }
}

// The wall clock in `tz` at this instant. Panics outside MIN_YEAR..MAX_YEAR.
pub fn to_datetime(self: Instant, tz: TimeZone) DateTime {
    const offset = tz.offset_at(self) as i64 * TICKS_PER_SECOND
    return datetime_from_ticks(checked_add(self.ticks, offset))
}

pub fn to_offset_datetime(self: Instant, tz: TimeZone) OffsetDateTime {
    return OffsetDateTime { instant = self, offset = tz.offset_at(self) }
}

// The instant at which the wall clock in `tz` reads `self`. A reading the zone skips (the hour lost
// when clocks spring forward) is taken at the offset before the change, landing as far past the gap
// as it was into it; a reading the zone repeats (clocks falling back) resolves to the earlier of
// the two. This is Temporal's "compatible" disambiguation, which C# and Python's fold=0 follow too.
// Panics outside MIN_YEAR..MAX_YEAR.
pub fn to_instant(self: DateTime, tz: TimeZone) Instant {
    return instant_from_ticks(utc_of_wall(self, tz))
}

// The UTC ticks of the wall-clock reading `dt` in `tz`, unchecked; see to_instant.
fn utc_of_wall(dt: DateTime, tz: TimeZone) i64 {
    const before = tz.offset_at(Instant { ticks = dt.ticks - TICKS_PER_DAY })
    const after = tz.offset_at(Instant { ticks = dt.ticks + TICKS_PER_DAY })
    const at_before = dt.ticks - before as i64 * TICKS_PER_SECOND
    const at_after = dt.ticks - after as i64 * TICKS_PER_SECOND
    const before_holds = tz.offset_at(Instant { ticks = at_before }) == before
    const after_holds = tz.offset_at(Instant { ticks = at_after }) == after
    if before_holds and after_holds {
        return min(at_before, at_after)
    }
    if after_holds {
        return at_after
    }
    return at_before
}

// =============================================================================
// OffsetDateTime
// =============================================================================

// The wall-clock reading `dt` at `offset_seconds` east of UTC. InvalidOffset for a day or more
// either way; OutOfRange when the instant falls outside MIN_YEAR..MAX_YEAR in UTC.
pub fn offset_datetime(dt: DateTime, offset_seconds: i32) Result(OffsetDateTime, TimeError) {
    if offset_seconds <= -86400 or offset_seconds >= 86400 {
        return Err(TimeError.InvalidOffset)
    }
    const at = Instant { ticks = utc_ticks(dt, offset_seconds)? }
    return Ok(OffsetDateTime { instant = at, offset = offset_seconds })
}

// The wall-clock reading `dt` in `tz`, resolved as to_instant does, at the offset `tz` has there.
// OutOfRange when the instant falls outside MIN_YEAR..MAX_YEAR in UTC.
fn in_zone(dt: DateTime, tz: TimeZone) Result(OffsetDateTime, TimeError) {
    const at = Instant { ticks = in_range(utc_of_wall(dt, tz))? }
    return Ok(OffsetDateTime { instant = at, offset = tz.offset_at(at) })
}

// The wall-clock reading at the offset.
pub fn datetime(self: OffsetDateTime) DateTime {
    return datetime_from_ticks(checked_add(
        self.instant.ticks,
        self.offset as i64 * TICKS_PER_SECOND,
    ))
}

// By instant, as C# compares DateTimeOffset: the same moment read at two offsets is equal.
pub fn op_cmp(a: OffsetDateTime, b: OffsetDateTime) Ord {
    return op_cmp(a.instant, b.instant)
}

// RFC 3339 (`2026-10-14T09:30:00+01:00`) for an empty spec, otherwise a strftime pattern
// (std.time.internal.common) on the wall clock at the offset.
pub fn format(self: OffsetDateTime, w: Writer, spec: String) {
    const local = self.datetime()
    if spec.len == 0 {
        local.format(w, spec)
        write_offset(w, self.offset, true)
        return
    }
    write_pattern(w, local.date(), local.time(), Some(self.offset), spec)
}

// Read an RFC 3339 timestamp, keeping its offset: `2026-10-14T09:30:00+01:00`, `...Z`. The time and
// the offset are required (BadFormat without either).
pub fn parse_offset_datetime(s: String) Result(OffsetDateTime, TimeError) {
    let sc = scanner(s)
    const read = sc.scan_timestamp()?
    return offset_datetime(read.0, read.1)
}

// Read an ISO 8601 date or date-time, with or without an offset (any text parse_datetime or
// parse_offset_datetime reads). Text without an offset is a wall-clock reading in `tz`, resolved as
// to_instant does and given the offset `tz` has there: pass TimeZone.Utc for UTC, `system_zone()?`
// for local time.
pub fn parse_offset_datetime(s: String, tz: TimeZone) Result(OffsetDateTime, TimeError) {
    let sc = scanner(s)
    const dt = sc.scan_datetime()?
    if sc.at_end() {
        return in_zone(dt, tz)
    }
    const offset = sc.scan_offset()?
    if !sc.at_end() {
        return Err(TimeError.BadFormat)
    }
    return offset_datetime(dt, offset)
}

// Read `s` laid out as `pattern` (std.time.internal.parse). The pattern needs the date and `%z` or
// `%Z` (BadFormat without them); `%z` wins when it has both.
pub fn parse_offset_datetime(s: String, pattern: String) Result(OffsetDateTime, TimeError) {
    return resolve(read_pattern(s, pattern)?, null)
}

// As parse_offset_datetime(s, pattern), reading the wall clock in `tz` when the pattern names no
// offset or zone.
pub fn parse_offset_datetime(
    s: String,
    pattern: String,
    tz: TimeZone,
) Result(OffsetDateTime, TimeError) {
    return resolve(read_pattern(s, pattern)?, Some(tz))
}

fn resolve(f: Fields, fallback: TimeZone?) Result(OffsetDateTime, TimeError) {
    const dt = f.to_datetime()?
    f.offset match {
        Some(offset) => return offset_datetime(dt, offset)
        None => {}
    }
    const tz = f.zone match {
        Some(z) => z
        None => fallback match {
            Some(z) => z
            None => return Err(TimeError.BadFormat)
        }
    }
    return in_zone(dt, tz)
}

// The instant of parse_offset_datetime(s, tz).
pub fn parse_instant(s: String, tz: TimeZone) Result(Instant, TimeError) {
    const odt = parse_offset_datetime(s, tz)?
    return Ok(odt.instant)
}

// The instant of parse_offset_datetime(s, pattern).
pub fn parse_instant(s: String, pattern: String) Result(Instant, TimeError) {
    const odt = parse_offset_datetime(s, pattern)?
    return Ok(odt.instant)
}

// Read an RFC 5322 date-time: `Tue, 14 Oct 2026 09:30:00 +0100`, as email `Date:` headers and HTTP
// carry it. The weekday and the seconds are optional, names match in any case, and parenthesised
// comments and line folds are skipped. The obsolete forms read too: 2- and 3-digit years (`26` is
// 2026, `99` is 1999, `126` is 2026), the zone names UT, GMT, UTC, EST, EDT, CST, CDT, MST, MDT,
// PST and PDT, and single military letters, which read as +00:00. A weekday that contradicts the
// date is InvalidDate.
pub fn parse_rfc5322(s: String) Result(OffsetDateTime, TimeError) {
    return resolve(read_rfc5322(s)?, null)
}

test "fixed zones and offset date-times" {
    const tz = fixed_zone(19800).unwrap()
    const i = parse_instant("2026-10-14T00:00:00Z").unwrap()
    assert_true(
        i.to_datetime(tz) == datetime(2026, Month.October, 14, 5, 30).unwrap(),
        "to_datetime",
    )
    assert_true(datetime(2026, Month.October, 14, 5, 30).unwrap().to_instant(tz) == i, "to_instant")
    assert_true(fixed_zone(86400).is_err(), "a day")
    const odt = i.to_offset_datetime(tz)
    const text = $"{odt}"
    defer text.deinit()
    assert_true(text.view == "2026-10-14T05:30:00+05:30", text.view)
    const parsed = parse_offset_datetime("2026-10-14T05:30:00+05:30").unwrap()
    assert_true(parsed == odt, "parse")
    assert_eq(parsed.offset, 19800i32, "keeps offset")
    assert_true(
        parse_offset_datetime("2026-10-14T00:00:00Z").unwrap() == odt,
        "same instant is equal",
    )
    assert_true(
        parse_offset_datetime("-009999-01-01T00:00:00+01:00").unwrap_err() == TimeError.OutOfRange,
        "past MIN_INSTANT",
    )
    const name = $"{tz} {TimeZone.Utc}"
    defer name.deinit()
    assert_true(name.view == "+05:30 UTC", name.view)
}

test "database zones follow DST" {
    const ny = zone("America/New_York") match {
        Ok(z) => z
        Err(_) => return
    }
    const winter = parse_instant("2026-01-15T12:00:00Z").unwrap()
    const summer = parse_instant("2026-07-01T12:00:00Z").unwrap()
    const far = parse_instant("2100-07-01T12:00:00Z").unwrap()
    assert_eq(ny.offset_at(winter), -18000i32, "EST")
    assert_eq(ny.offset_at(summer), -14400i32, "EDT")
    assert_eq(ny.offset_at(far), -14400i32, "past the last transition")
    const gap = datetime(2026, Month.March, 8, 2, 30).unwrap().to_instant(ny)
    assert_true(gap == parse_instant("2026-03-08T07:30:00Z").unwrap(), "gap moves forward")
    const overlap = datetime(2026, Month.November, 1, 1, 30).unwrap().to_instant(ny)
    assert_true(
        overlap == parse_instant("2026-11-01T05:30:00Z").unwrap(),
        "overlap takes the earlier",
    )
    assert_true(summer.to_datetime(ny) == datetime(2026, Month.July, 1, 8).unwrap(), "to_datetime")
    const name = $"{ny}"
    defer name.deinit()
    assert_true(name.view == "America/New_York", name.view)
    assert_true(zone("America/New_York").unwrap() == ny, "same handle")
    assert_true(zone("Not/AZone").unwrap_err() == TimeError.UnknownZone, "unknown")
    assert_true(
        zone("../etc/passwd").unwrap_err() == TimeError.UnknownZone,
        "stays in the database",
    )
    assert_true(system_zone().is_ok(), "system zone")
    const by_name = parse_offset_datetime("2026-07-01 08:00 America/New_York", "%F %H:%M %Z")
    assert_true(by_name.unwrap().instant == summer, "%Z")
    const gap_text = parse_offset_datetime("2026-03-08T02:30", ny).unwrap()
    assert_eq(gap_text.offset, -14400i32, "offset after the gap")
    assert_true(gap_text.instant == gap, "gap instant")
}

test "zone fields" {
    assert_true(parse_zone("utc").unwrap() == TimeZone.Utc, "utc")
    assert_true(parse_zone("Z").unwrap() == TimeZone.Utc, "Z")
    assert_true(parse_zone("GMT").unwrap() == TimeZone.Utc, "GMT")
    assert_true(parse_zone("+05:30").unwrap() == TimeZone.Fixed(19800), "+05:30")
    assert_true(parse_zone("-0500").unwrap() == TimeZone.Fixed(-18000), "-0500")
    assert_true(parse_zone("+01").unwrap() == TimeZone.Fixed(3600), "+01")
    assert_true(parse_zone("UTC+1").unwrap() == TimeZone.Fixed(3600), "UTC+1")
    assert_true(parse_zone("GMT-05:00").unwrap() == TimeZone.Fixed(-18000), "GMT-05:00")
    assert_true(parse_zone("pdt").unwrap() == TimeZone.Fixed(-25200), "PDT")
    assert_true(parse_zone("IST").unwrap_err() == TimeError.UnknownZone, "ambiguous")
    assert_true(parse_zone("+25").unwrap_err() == TimeError.InvalidOffset, "+25")
    assert_true(parse_zone("UTC+1x").unwrap_err() == TimeError.BadFormat, "trailing")
}

test "lenient and pattern offset date-times" {
    const utc = parse_offset_datetime("2026-10-14T09:30", TimeZone.Utc).unwrap()
    assert_true(utc.instant == parse_instant("2026-10-14T09:30:00Z").unwrap(), "no offset is utc")
    assert_eq(utc.offset, 0i32, "utc offset")
    const tz = fixed_zone(3600).unwrap()
    const kept = parse_offset_datetime("2026-10-14T09:30-05:00", tz).unwrap()
    assert_eq(kept.offset, -18000i32, "text offset wins")
    const midnight = parse_instant("2026-10-14", tz).unwrap()
    assert_true(midnight == parse_instant("2026-10-13T23:00:00Z").unwrap(), "date only")
    assert_true(
        parse_offset_datetime("2026-10-14T09:30:00").unwrap_err() == TimeError.BadFormat,
        "strict wants an offset",
    )
    assert_true(
        parse_offset_datetime("2026-10-14+01:00").unwrap_err() == TimeError.BadFormat,
        "strict wants a time",
    )
    const p = parse_offset_datetime("14.10.2026 10:30 +01:00", "%d.%m.%Y %H:%M %z").unwrap()
    assert_true(p.instant == utc.instant, "pattern")
    assert_eq(p.offset, 3600i32, "pattern offset")
    assert_true(
        parse_offset_datetime(
            "14.10.2026 10:30",
            "%d.%m.%Y %H:%M",
        ).unwrap_err() == TimeError.BadFormat,
        "pattern without a zone",
    )
    const fallback = parse_offset_datetime("14.10.2026 10:30", "%d.%m.%Y %H:%M", tz).unwrap()
    assert_true(fallback.instant == utc.instant, "pattern fallback zone")
    assert_true(
        parse_instant("14.10.2026 09:30 GMT", "%d.%m.%Y %H:%M %z").unwrap() == utc.instant,
        "GMT",
    )
}

test "rfc 5322 dates" {
    const expected = parse_instant("2026-10-14T08:30:00Z").unwrap()
    const full = parse_rfc5322("Wed, 14 Oct 2026 09:30:00 +0100").unwrap()
    assert_true(full.instant == expected, "full")
    assert_eq(full.offset, 3600i32, "offset")
    assert_true(parse_rfc5322("14 Oct 2026 08:30 GMT").unwrap().instant == expected, "short")
    assert_true(
        parse_rfc5322("wed,14 oct 2026 04:30:00 EDT (Eastern)").unwrap().instant == expected,
        "comment and EDT",
    )
    assert_true(
        parse_rfc5322("Wed, 14 Oct 26 08:30:00\r\n +0000").unwrap().instant == expected,
        "2-digit year, folded",
    )
    assert_true(parse_rfc5322("Wed, 14 Oct 126 08:30 Z").unwrap().instant == expected, "3 digits")
    assert_true(
        parse_rfc5322("Thu, 14 Oct 2026 09:30:00 +0100").unwrap_err() == TimeError.InvalidDate,
        "wrong weekday",
    )
    assert_true(parse_rfc5322("14 Oct 2026 09:30 +0100 (open").is_err(), "unclosed comment")
    assert_true(parse_rfc5322("14 Oct 2026 09:30").is_err(), "no zone")
    const text = $"{full:%a, %d %b %Y %H:%M:%S %z}"
    defer text.deinit()
    assert_true(parse_rfc5322(text.view).unwrap() == full, text.view)
}
