// std.time.time - a wall-clock time with no date and no time zone (C# TimeOnly, Python time,
// Temporal PlainTime, chrono NaiveTime).
//
// A `Time` is ticks since midnight, 0 up to one day exclusive, at 100 ns resolution. Arithmetic
// wraps around midnight, as a clock does.

import std.format
import std.io.writer
import std.result
import std.string
import std.string_builder
import std.test
import std.time.calendar
import std.time.date
import std.time.duration
import std.time.internal.common
import std.time.internal.parse

pub type Time = struct {
    ticks: i64
}

// The time `hour`:`minute`:`second`. `nanosecond` truncates to 100 ns ticks. InvalidTime for any
// field outside its range; 24:00 is not a time.
pub fn time(hour: i32, minute: i32, second: i32 = 0, nanosecond: i32 = 0) Result(Time, TimeError) {
    const valid = hour >= 0 and hour < 24 and minute >= 0 and minute < 60 and second >= 0
        and second < 60
    if !valid or nanosecond < 0 or nanosecond > 999999999 {
        return Err(TimeError.InvalidTime)
    }
    const ticks = hour as i64 * TICKS_PER_HOUR + minute as i64 * TICKS_PER_MINUTE +
    second as i64 * TICKS_PER_SECOND + nanosecond as i64 / 100
    return Ok(Time { ticks })
}

pub fn hour(self: Time) i32 {
    return (self.ticks / TICKS_PER_HOUR) as i32
}

pub fn minute(self: Time) i32 {
    return (self.ticks % TICKS_PER_HOUR / TICKS_PER_MINUTE) as i32
}

pub fn second(self: Time) i32 {
    return (self.ticks % TICKS_PER_MINUTE / TICKS_PER_SECOND) as i32
}

// 0-999, the milliseconds within the second.
pub fn millisecond(self: Time) i32 {
    return (self.ticks % TICKS_PER_SECOND / TICKS_PER_MILLISECOND) as i32
}

// 0-999, the microseconds within the millisecond.
pub fn microsecond(self: Time) i32 {
    return (self.ticks % TICKS_PER_MILLISECOND / TICKS_PER_MICROSECOND) as i32
}

// 0-900 in steps of 100, the nanoseconds within the microsecond.
pub fn nanosecond(self: Time) i32 {
    return (self.ticks % TICKS_PER_MICROSECOND * 100) as i32
}

// Wraps around midnight: 23:00 plus two hours is 01:00.
pub fn op_add(a: Time, d: Duration) Time {
    return Time { ticks = mod_floor(a.ticks + d.ticks % TICKS_PER_DAY, TICKS_PER_DAY) }
}

pub fn op_sub(a: Time, d: Duration) Time {
    return a + op_neg(d)
}

// Signed: 01:00 - 23:00 is -22 hours, not 2.
pub fn op_sub(a: Time, b: Time) Duration {
    return ticks(a.ticks - b.ticks)
}

pub fn op_cmp(a: Time, b: Time) Ord {
    return op_cmp(a.ticks, b.ticks)
}

// ISO 8601 (`13:45:00`, `13:45:00.5`) for an empty spec, otherwise a strftime pattern
// (std.time.internal.common) with the date fields at 1970-01-01.
pub fn format(self: Time, w: Writer, spec: String) {
    if spec.len == 0 {
        write_time(w, self)
        return
    }
    write_pattern(w, date_from_epoch_day(0), self, null, spec)
}

// Read an ISO 8601 time: `13:45`, `13:45:30`, `13:45:30.1234567`.
pub fn parse_time(s: String) Result(Time, TimeError) {
    let sc = scanner(s)
    const t = sc.scan_time()?
    if !sc.at_end() {
        return Err(TimeError.BadFormat)
    }
    return Ok(t)
}

// Read `s` laid out as `pattern` (std.time.internal.parse): `parse_time("9:05 PM", "%I:%M %p")`.
// Fields the pattern leaves out are 0; date and zone fields are read and dropped.
pub fn parse_time(s: String, pattern: String) Result(Time, TimeError) {
    const f = read_pattern(s, pattern)?
    return f.to_time()
}

test "time fields" {
    const t = time(13, 45, 30, 123456789).unwrap()
    assert_eq(t.hour(), 13i32, "hour")
    assert_eq(t.minute(), 45i32, "minute")
    assert_eq(t.second(), 30i32, "second")
    assert_eq(t.millisecond(), 123i32, "ms")
    assert_eq(t.microsecond(), 456i32, "us")
    assert_eq(t.nanosecond(), 700i32, "ns truncated to ticks")
    assert_true(time(24, 0).is_err(), "24:00")
    assert_true(time(12, 60).is_err(), "minute 60")
}

test "time arithmetic wraps" {
    const late = time(23, 0).unwrap()
    assert_true(late + hours(2) == time(1, 0).unwrap(), "past midnight")
    assert_true(time(1, 0).unwrap() - hours(2) == late, "before midnight")
    assert_true(late + days(-3) == late, "whole days")
    assert_true(time(1, 0).unwrap() - late == hours(-22), "signed difference")
}

test "time text" {
    const t = time(9, 5, 7, 500000000).unwrap()
    const iso = $"{t}"
    defer iso.deinit()
    assert_true(iso.view == "09:05:07.5", iso.view)
    const custom = $"{t:%H.%M.%S.%f}"
    defer custom.deinit()
    assert_true(custom.view == "09.05.07.500000", custom.view)
    assert_true(parse_time("09:05:07.5").unwrap() == t, "parse")
    assert_true(parse_time("09:05").unwrap() == time(9, 5).unwrap(), "no seconds")
    assert_true(parse_time("23:59:60").unwrap() == time(23, 59, 59).unwrap(), "leap second")
    assert_true(parse_time("25:00").unwrap_err() == TimeError.InvalidTime, "hour 25")
    assert_true(parse_time("9:05").unwrap_err() == TimeError.BadFormat, "one-digit hour")
}

test "time patterns" {
    assert_true(parse_time("9:05 PM", "%I:%M %p").unwrap() == time(21, 5).unwrap(), "pm")
    assert_true(parse_time("12:30 am", "%I:%M %p").unwrap() == time(0, 30).unwrap(), "midnight")
    assert_true(parse_time("12:30", "%I:%M").unwrap() == time(0, 30).unwrap(), "no %p is am")
    assert_true(
        parse_time("10.5.7,25", "%H.%M.%S,%f").unwrap() == time(10, 5, 7, 250000000).unwrap(),
        "fraction",
    )
    assert_true(parse_time("13 PM", "%I %p").unwrap_err() == TimeError.InvalidTime, "13 PM")
    assert_true(parse_time("09:05", "%H:%M:%S").unwrap_err() == TimeError.BadFormat, "short")
    const t = time(21, 5).unwrap()
    const text = $"{t:%I:%M %p}"
    defer text.deinit()
    assert_true(text.view == "09:05 PM", text.view)
}
