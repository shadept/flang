// std.time.datetime - a calendar date and a wall-clock time, with no time zone (Temporal
// PlainDateTime, Python naive datetime, chrono NaiveDateTime, Java LocalDateTime).
//
// A `DateTime` is what a wall clock and a calendar on the wall read, not a point on the timeline:
// "2026-10-14 09:00" happens once in each time zone, and some readings happen twice or never on the
// day a zone changes its clock. To reach the timeline, name the zone: `dt.to_instant(tz)`
// (std.time.zone). For a point on the timeline, use an Instant (std.time.instant).
//
// It is 8 bytes: 100 ns ticks since 1970-01-01T00:00 on the same wall clock, so ordering and
// differences are integer operations. Duration arithmetic is wall-clock arithmetic: 24 hours after
// 01:00 is 01:00 the next day, whatever a zone did in between.

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
import std.time.time

pub type DateTime = struct {
    ticks: i64
}

pub fn datetime(d: Date, t: Time) DateTime {
    return DateTime { ticks = d.epoch_day as i64 * TICKS_PER_DAY + t.ticks }
}

// The date-time from its fields; the errors of `date` and `time`.
pub fn datetime(
    year: i32,
    month: Month,
    day: i32,
    hour: i32 = 0,
    minute: i32 = 0,
    second: i32 = 0,
    nanosecond: i32 = 0,
) Result(DateTime, TimeError) {
    const d = date(year, month, day)?
    const t = time(hour, minute, second, nanosecond)?
    return Ok(datetime(d, t))
}

// The date-time `ticks` after 1970-01-01T00:00. Panics outside MIN_YEAR..MAX_YEAR.
pub fn datetime_from_ticks(ticks: i64) DateTime {
    const first = MIN_EPOCH_DAY * TICKS_PER_DAY
    const last = (MAX_EPOCH_DAY + 1) * TICKS_PER_DAY - 1
    if ticks < first or ticks > last {
        out_of_range()
    }
    return DateTime { ticks }
}

pub fn at(self: Date, t: Time) DateTime {
    return datetime(self, t)
}

pub fn date(self: DateTime) Date {
    return date_from_epoch_day(div_floor(self.ticks, TICKS_PER_DAY))
}

pub fn time(self: DateTime) Time {
    return Time { ticks = mod_floor(self.ticks, TICKS_PER_DAY) }
}

pub fn year(self: DateTime) i32 {
    return self.date().year()
}

pub fn month(self: DateTime) Month {
    return self.date().month()
}

pub fn day(self: DateTime) i32 {
    return self.date().day()
}

pub fn weekday(self: DateTime) Weekday {
    return self.date().weekday()
}

pub fn day_of_year(self: DateTime) i32 {
    return self.date().day_of_year()
}

pub fn hour(self: DateTime) i32 {
    return self.time().hour()
}

pub fn minute(self: DateTime) i32 {
    return self.time().minute()
}

pub fn second(self: DateTime) i32 {
    return self.time().second()
}

pub fn nanosecond(self: DateTime) i32 {
    return self.time().nanosecond()
}

// Panics outside MIN_YEAR..MAX_YEAR.
pub fn op_add(a: DateTime, d: Duration) DateTime {
    return datetime_from_ticks(checked_add(a.ticks, d.ticks))
}

pub fn op_sub(a: DateTime, d: Duration) DateTime {
    return datetime_from_ticks(checked_add(a.ticks, -d.ticks))
}

pub fn op_sub(a: DateTime, b: DateTime) Duration {
    return ticks(a.ticks - b.ticks)
}

// The date moves by the period (see Date's op_add); the time of day stays.
pub fn op_add(a: DateTime, p: Period) DateTime {
    return datetime(a.date() + p, a.time())
}

pub fn op_sub(a: DateTime, p: Period) DateTime {
    return datetime(a.date() - p, a.time())
}

pub fn op_cmp(a: DateTime, b: DateTime) Ord {
    return op_cmp(a.ticks, b.ticks)
}

// ISO 8601 (`2026-10-14T09:30:00`) for an empty spec, otherwise a strftime pattern
// (std.time.internal.common).
pub fn format(self: DateTime, w: Writer, spec: String) {
    if spec.len == 0 {
        write_date(w, self.date())
        w.write_byte('T')
        write_time(w, self.time())
        return
    }
    write_pattern(w, self.date(), self.time(), null, spec)
}

// Read an ISO 8601 date-time: a date, `T` (or a space), and a time - `2026-10-14T09:30`,
// `2026-10-14 09:30:00.25`. A date alone reads as its midnight. An offset or `Z` is refused
// (BadFormat): that text names an instant, read by parse_instant or parse_offset_datetime.
pub fn parse_datetime(s: String) Result(DateTime, TimeError) {
    let sc = scanner(s)
    const dt = sc.scan_datetime()?
    if !sc.at_end() {
        return Err(TimeError.BadFormat)
    }
    return Ok(dt)
}

// Read `s` laid out as `pattern` (std.time.internal.parse): `parse_datetime("7/4/2026 9:05 PM",
// "%m/%d/%Y %I:%M %p")`. The date fields are required as for parse_date(s, pattern); time fields
// left out are 0; zone fields are read and dropped.
pub fn parse_datetime(s: String, pattern: String) Result(DateTime, TimeError) {
    const f = read_pattern(s, pattern)?
    return f.to_datetime()
}

test "datetime fields and conversions" {
    const dt = datetime(2026, Month.October, 14, 9, 30, 15).unwrap()
    assert_eq(dt.year(), 2026i32, "year")
    assert_eq(dt.hour(), 9i32, "hour")
    assert_eq(dt.second(), 15i32, "second")
    assert_true(dt.date() == date(2026, Month.October, 14).unwrap(), "date")
    assert_true(dt.time() == time(9, 30, 15).unwrap(), "time")
    const before_epoch = datetime(1969, Month.December, 31, 23).unwrap()
    assert_true(before_epoch.date() == date(1969, Month.December, 31).unwrap(), "negative ticks")
    assert_eq(before_epoch.hour(), 23i32, "negative ticks hour")
    assert_true(datetime(2026, Month.February, 30).unwrap_err() == TimeError.InvalidDate, "invalid")
}

test "datetime arithmetic" {
    const dt = datetime(2024, Month.January, 31, 22).unwrap()
    assert_true(dt + hours(3) == datetime(2024, Month.February, 1, 1).unwrap(), "duration")
    assert_true(
        dt + period(months = 1) == datetime(2024, Month.February, 29, 22).unwrap(),
        "period",
    )
    assert_true(dt - datetime(2024, Month.January, 30, 22).unwrap() == days(1), "difference")
    assert_true(
        dt - hours(22) == date(2024, Month.January, 31).unwrap().at(time(0, 0).unwrap()),
        "back",
    )
}

test "datetime text" {
    const dt = datetime(2026, Month.October, 14, 9, 30, 0, 250000000).unwrap()
    const iso = $"{dt}"
    defer iso.deinit()
    assert_true(iso.view == "2026-10-14T09:30:00.25", iso.view)
    const custom = $"{dt:%F %T}"
    defer custom.deinit()
    assert_true(custom.view == "2026-10-14 09:30:00", custom.view)
    assert_true(parse_datetime("2026-10-14T09:30:00.25").unwrap() == dt, "parse")
    assert_true(parse_datetime("2026-10-14 09:30:00.25").unwrap() == dt, "space")
    assert_true(parse_datetime("2026-10-14").unwrap().hour() == 0i32, "date only")
    assert_true(
        parse_datetime("2026-10-14T09:30Z").unwrap_err() == TimeError.BadFormat,
        "offset refused",
    )
}

test "datetime patterns" {
    const dt = datetime(2026, Month.July, 4, 21, 5).unwrap()
    assert_true(parse_datetime("7/4/2026 9:05 PM", "%m/%d/%Y %I:%M %p").unwrap() == dt, "us")
    assert_true(parse_datetime("2026-07-04 21:05:00", "%F %T").unwrap() == dt, "%F %T")
    assert_true(parse_datetime("2026-07-04", "%F").unwrap().hour() == 0i32, "midnight")
    assert_true(
        parse_datetime("2026-07-04 21:05 +0100", "%F %H:%M %z").unwrap() == dt,
        "offset dropped",
    )
    assert_true(parse_datetime("100% 2026-07-04", "100%% %F").is_ok(), "literal %")
}
