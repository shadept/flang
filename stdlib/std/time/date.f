// std.time.date - a calendar date with no time of day and no time zone (C# DateOnly, Python date,
// Temporal PlainDate, chrono NaiveDate).
//
// A `Date` is a day on the calendar, not a span of time: "2026-10-14" begins at a different instant
// in every time zone. It stores its epoch day (std.time.calendar), 4 bytes, ordered and compared as
// an integer.

import std.format
import std.io.writer
import std.result
import std.string
import std.string_builder
import std.test
import std.time.calendar
import std.time.duration
import std.time.internal.common
import std.time.internal.parse

pub type Date = struct {
    epoch_day: i32
}

// The date `year`-`month`-`day`. InvalidDate when the day is not in that month or the month is not
// a Month (`n as Month` for an n of 13); OutOfRange outside MIN_YEAR..MAX_YEAR.
pub fn date(year: i32, month: Month, day: i32) Result(Date, TimeError) {
    const m = month as i32
    if m < 1 or m > 12 {
        return Err(TimeError.InvalidDate)
    }
    if year < MIN_YEAR or year > MAX_YEAR {
        return Err(TimeError.OutOfRange)
    }
    if day < 1 or day > days_in_month(year, month) {
        return Err(TimeError.InvalidDate)
    }
    return Ok(Date { epoch_day = days_from_civil(year, month, day) as i32 })
}

// The date `n` days after 1970-01-01. Panics outside MIN_EPOCH_DAY..MAX_EPOCH_DAY.
pub fn date_from_epoch_day(n: i64) Date {
    if n < MIN_EPOCH_DAY or n > MAX_EPOCH_DAY {
        out_of_range()
    }
    return Date { epoch_day = n as i32 }
}

pub fn year(self: Date) i32 {
    return civil_from_days(self.epoch_day as i64).0
}

pub fn month(self: Date) Month {
    return civil_from_days(self.epoch_day as i64).1
}

pub fn day(self: Date) i32 {
    return civil_from_days(self.epoch_day as i64).2
}

pub fn weekday(self: Date) Weekday {
    return weekday_from_days(self.epoch_day as i64)
}

// 1 for January 1.
pub fn day_of_year(self: Date) i32 {
    return (self.epoch_day as i64 - days_from_civil(self.year(), Month.January, 1) + 1) as i32
}

// The ISO 8601 week date as (week-numbering year, week 1-53). Week 1 is the week holding the year's
// first Thursday, so early January can belong to the previous year's last week.
pub fn iso_week(self: Date) (i32, i32) {
    const thursday = self.epoch_day as i64 - (self.weekday() as i64 - 1) + 3
    const year = civil_from_days(thursday).0
    const week = (thursday - days_from_civil(year, Month.January, 1)) / 7 + 1
    return (year, week as i32)
}

// Add years and months first, clamping the day to the resulting month's length, then days - the
// order Java, NodaTime and Temporal use. January 31 plus one month is February 28 or 29. Panics
// outside MIN_YEAR..MAX_YEAR.
pub fn op_add(a: Date, p: Period) Date {
    const ymd = civil_from_days(a.epoch_day as i64)
    const months = (ymd.0 as i64 + p.years as i64) * 12 + (ymd.1 as i64 - 1) + p.months as i64
    const year = div_floor(months, 12i64)
    if year < MIN_YEAR as i64 or year > MAX_YEAR as i64 {
        out_of_range()
    }
    const month = (mod_floor(months, 12i64) + 1) as i32 as Month
    const day = min(ymd.2, days_in_month(year as i32, month))
    return date_from_epoch_day(days_from_civil(year as i32, month, day) + p.days as i64)
}

pub fn op_sub(a: Date, p: Period) Date {
    return a + op_neg(p)
}

pub fn op_cmp(a: Date, b: Date) Ord {
    return op_cmp(a.epoch_day, b.epoch_day)
}

// Days from `self` to `other`, negative when `other` is earlier.
pub fn days_until(self: Date, other: Date) i64 {
    return other.epoch_day as i64 - self.epoch_day as i64
}

// The period from `self` to `other` in years, months and days, such that `self + p == other`. Every
// field takes the sign of the direction. Java's Period.between.
pub fn until(self: Date, other: Date) Period {
    const from = civil_from_days(self.epoch_day as i64)
    const to = civil_from_days(other.epoch_day as i64)
    let months = (to.0 as i64 * 12 + to.1 as i64) - (from.0 as i64 * 12 + from.1 as i64)
    let days = (to.2 - from.2) as i64
    if months > 0 and days < 0 {
        months = months - 1
        const anchor = self + period(months = months as i32)
        days = anchor.days_until(other)
    }
    else if months < 0 and days > 0 {
        months = months + 1
        days = days - days_in_month(to.0, to.1) as i64
    }
    return period(years = (months / 12) as i32, months = (months % 12) as i32, days = days as i32)
}

// ISO 8601 (`2026-10-14`) for an empty spec, otherwise a strftime pattern
// (std.time.internal.common) with the time fields at midnight.
pub fn format(self: Date, w: Writer, spec: String) {
    if spec.len == 0 {
        write_date(w, self)
        return
    }
    write_pattern(w, self, Time { ticks = 0 }, null, spec)
}

// Read an ISO 8601 calendar date: `2026-10-14`, or `+012026-10-14` / `-000044-03-15` for years past
// four digits or before year 0.
pub fn parse_date(s: String) Result(Date, TimeError) {
    let sc = scanner(s)
    const d = sc.scan_date()?
    if !sc.at_end() {
        return Err(TimeError.BadFormat)
    }
    return Ok(d)
}

// Read `s` laid out as `pattern` (std.time.internal.parse): `parse_date("4/7/2026", "%d/%m/%Y")`.
// The pattern needs a year, and a month and day or a day of year (BadFormat without them); time and
// zone fields are read and dropped.
pub fn parse_date(s: String, pattern: String) Result(Date, TimeError) {
    const f = read_pattern(s, pattern)?
    return f.to_date()
}

test "date validation" {
    assert_true(date(2024, Month.February, 29).is_ok(), "leap day")
    assert_true(date(2023, Month.February, 29).unwrap_err() == TimeError.InvalidDate, "no leap day")
    assert_true(date(2023, Month.April, 31).is_err(), "April 31")
    assert_true(date(2023, Month.April, 0).is_err(), "day 0")
    assert_true(date(10000, Month.January, 1).unwrap_err() == TimeError.OutOfRange, "year 10000")
    const thirteen = 13i32
    assert_true(date(2023, thirteen as Month, 1).unwrap_err() == TimeError.InvalidDate, "month 13")
}

test "date fields" {
    const d = date(2026, Month.October, 14).unwrap()
    assert_eq(d.year(), 2026i32, "year")
    assert_true(d.month() == Month.October, "month")
    assert_eq(d.day(), 14i32, "day")
    assert_true(d.weekday() == Weekday.Wednesday, "weekday")
    assert_eq(d.day_of_year(), 287i32, "day of year")
    assert_eq(d.iso_week().1, 42i32, "iso week")
    const jan1 = date(2021, Month.January, 1).unwrap()
    assert_eq(jan1.iso_week().0, 2020i32, "2021-01-01 is in 2020's week")
    assert_eq(jan1.iso_week().1, 53i32, "week 53")
}

test "date arithmetic" {
    const jan31 = date(2024, Month.January, 31).unwrap()
    assert_true(jan31 + period(months = 1) == date(2024, Month.February, 29).unwrap(), "clamps")
    assert_true(
        jan31 + period(years = 1, months = 1) == date(2025, Month.February, 28).unwrap(),
        "clamps",
    )
    assert_true(jan31 + period(days = 1) == date(2024, Month.February, 1).unwrap(), "days")
    assert_true(jan31 - period(months = 2) == date(2023, Month.November, 30).unwrap(), "back")
    const a = date(2020, Month.January, 31).unwrap()
    const b = date(2021, Month.March, 1).unwrap()
    assert_true(a.until(b) == period(years = 1, months = 1, days = 1), "until")
    assert_true(b.until(a) == period(years = -1, months = -1, days = -1), "until backwards")
    assert_eq(a.days_until(b), 395i64, "days_until")
    assert_true(a < b, "ordered")
}

test "date text" {
    const d = date(2026, Month.October, 4).unwrap()
    const iso = $"{d}"
    defer iso.deinit()
    assert_true(iso.view == "2026-10-04", "iso")
    const custom = $"{d:%a %d %B %Y, day %j}"
    defer custom.deinit()
    assert_true(custom.view == "Sun 04 October 2026, day 277", custom.view)
    assert_true(parse_date("2026-10-04").unwrap() == d, "parse")
    assert_true(parse_date("-000044-03-15").unwrap().year() == -44i32, "extended year")
    const old = $"{parse_date("-000044-03-15").unwrap()}"
    defer old.deinit()
    assert_true(old.view == "-000044-03-15", "extended year format")
    assert_true(parse_date("2026-02-30").unwrap_err() == TimeError.InvalidDate, "invalid")
    assert_true(parse_date("2026-1-01").unwrap_err() == TimeError.BadFormat, "short month")
    assert_true(parse_date("2026-10-04x").is_err(), "trailing")
}

test "date patterns" {
    const d = date(2026, Month.July, 4).unwrap()
    assert_true(parse_date("4/7/2026", "%d/%m/%Y").unwrap() == d, "unpadded")
    assert_true(parse_date("20260704", "%Y%m%d").unwrap() == d, "packed")
    assert_true(parse_date("Saturday, JULY  4 26", "%A, %B %e %y").unwrap() == d, "names")
    assert_true(parse_date("sat 04 jul 2026", "%a %d %b %Y").unwrap() == d, "short names")
    assert_true(parse_date("2026.185", "%Y.%j").unwrap() == d, "day of year")
    assert_true(parse_date("70-01-01", "%y-%m-%d").unwrap().year() == 1970i32, "pivot 70")
    assert_true(parse_date("68-01-01", "%y-%m-%d").unwrap().year() == 2068i32, "pivot 68")
    assert_true(
        parse_date("Mon 4 Jul 2026", "%a %d %b %Y").unwrap_err() == TimeError.InvalidDate,
        "wrong weekday",
    )
    assert_true(parse_date("31/2/2026", "%d/%m/%Y").unwrap_err() == TimeError.InvalidDate, "Feb 31")
    assert_true(parse_date("7/2026", "%m/%Y").unwrap_err() == TimeError.BadFormat, "no day")
    assert_true(parse_date("2026-07-04", "%G-%m-%d").unwrap_err() == TimeError.BadFormat, "%G")
    const text = $"{d:%e %b %y}"
    defer text.deinit()
    assert_true(parse_date(text.view, "%e %b %y").unwrap() == d, text.view)
}
