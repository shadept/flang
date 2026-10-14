// std.time.instant - an exact point on the timeline (Temporal Instant, Rust SystemTime, the UTC
// ticks of a C# DateTimeOffset).
//
// An `Instant` is the same moment everywhere: no calendar, no zone. It is 100 ns ticks since the
// Unix epoch, 1970-01-01T00:00:00Z, ignoring leap seconds as POSIX time does. Read the clock with
// `now()` (std.time.clock); see it on a calendar with `i.to_datetime(tz)` (std.time.zone).

import std.format
import std.io.writer
import std.result
import std.string
import std.string_builder
import std.test
import std.time.calendar
import std.time.datetime
import std.time.duration
import std.time.internal.common
import std.time.internal.parse

pub type Instant = struct {
    ticks: i64
}

// 1970-01-01T00:00:00Z, also the zero value.
pub const UNIX_EPOCH: Instant = Instant { ticks = 0 }

// -9999-01-01T00:00:00Z and the last tick of 9999-12-31 UTC.
pub const MIN_INSTANT: Instant = Instant { ticks = -3777051168000000000 }
pub const MAX_INSTANT: Instant = Instant { ticks = 2534023007999999999 }

// The instant `ticks` after the Unix epoch. Panics outside MIN_YEAR..MAX_YEAR (UTC).
pub fn instant_from_ticks(ticks: i64) Instant {
    return Instant { ticks = datetime_from_ticks(ticks).ticks }
}

pub fn from_unix_seconds(seconds: i64) Instant {
    return instant_from_ticks(scaled(seconds, TICKS_PER_SECOND))
}

pub fn from_unix_millis(millis: i64) Instant {
    return instant_from_ticks(scaled(millis, TICKS_PER_MILLISECOND))
}

// Whole seconds since the epoch, rounded down: one tick before the epoch is second -1.
pub fn unix_seconds(self: Instant) i64 {
    return div_floor(self.ticks, TICKS_PER_SECOND)
}

pub fn unix_millis(self: Instant) i64 {
    return div_floor(self.ticks, TICKS_PER_MILLISECOND)
}

// Panics outside MIN_YEAR..MAX_YEAR.
pub fn op_add(a: Instant, d: Duration) Instant {
    return instant_from_ticks(checked_add(a.ticks, d.ticks))
}

pub fn op_sub(a: Instant, d: Duration) Instant {
    return instant_from_ticks(checked_add(a.ticks, -d.ticks))
}

pub fn op_sub(a: Instant, b: Instant) Duration {
    return ticks(a.ticks - b.ticks)
}

pub fn op_cmp(a: Instant, b: Instant) Ord {
    return op_cmp(a.ticks, b.ticks)
}

// RFC 3339 in UTC (`2026-10-14T09:30:00Z`) for an empty spec, otherwise a strftime pattern
// (std.time.internal.common) on the UTC calendar, `%z` reading `+0000`.
pub fn format(self: Instant, w: Writer, spec: String) {
    const utc = DateTime { ticks = self.ticks }
    if spec.len == 0 {
        utc.format(w, spec)
        w.write_byte('Z')
        return
    }
    write_pattern(w, utc.date(), utc.time(), Some(0i32), spec)
}

// Read an RFC 3339 timestamp: `2026-10-14T09:30:00Z`, `2026-10-14T10:30:00+01:00`. The time and the
// offset are required (BadFormat without either): without them the text names no instant. To read
// text that may lack them, see parse_instant(s, tz) in std.time.zone.
pub fn parse_instant(s: String) Result(Instant, TimeError) {
    let sc = scanner(s)
    const read = sc.scan_timestamp()?
    return Ok(Instant { ticks = utc_ticks(read.0, read.1)? })
}

test "instant unix conversions" {
    const i = from_unix_seconds(1760434200)
    assert_eq(i.unix_seconds(), 1760434200i64, "seconds")
    assert_eq(i.unix_millis(), 1760434200000i64, "millis")
    assert_eq(instant_from_ticks(-1).unix_seconds(), -1i64, "floors")
    assert_true(i + seconds(1) - i == seconds(1), "arithmetic")
}

test "instant bounds" {
    assert_true(MIN_INSTANT == instant_from_ticks(MIN_EPOCH_DAY * TICKS_PER_DAY), "min")
    assert_true(UNIX_EPOCH == from_unix_seconds(0), "epoch")
    assert_true(MAX_INSTANT == instant_from_ticks((MAX_EPOCH_DAY + 1) * TICKS_PER_DAY - 1), "max")
    const text = $"{MIN_INSTANT} {MAX_INSTANT}"
    defer text.deinit()
    assert_true(text.view == "-009999-01-01T00:00:00Z 9999-12-31T23:59:59.9999999Z", text.view)
}

test "instant text" {
    const i = from_unix_seconds(1760434200)
    const iso = $"{i}"
    defer iso.deinit()
    assert_true(iso.view == "2025-10-14T09:30:00Z", iso.view)
    assert_true(parse_instant("2025-10-14T09:30:00Z").unwrap() == i, "Z")
    assert_true(parse_instant("2025-10-14T10:30:00+01:00").unwrap() == i, "offset")
    assert_true(parse_instant("2025-10-14T04:30:00-0500").unwrap() == i, "basic offset")
    assert_true(
        parse_instant("2025-10-14T09:30:00").unwrap_err() == TimeError.BadFormat,
        "no offset",
    )
    assert_true(parse_instant("2025-10-14Z").unwrap_err() == TimeError.BadFormat, "no time")
    assert_true(
        parse_instant("2025-10-14T09:30:00+24:00").unwrap_err() == TimeError.InvalidOffset,
        "offset range",
    )
    assert_true(
        parse_instant("9999-12-31T23:59:59-01:00").unwrap_err() == TimeError.OutOfRange,
        "past MAX_INSTANT",
    )
    const custom = $"{i:%Y%m%dT%H%M%S%z}"
    defer custom.deinit()
    assert_true(custom.view == "20251014T093000+0000", custom.view)
}
