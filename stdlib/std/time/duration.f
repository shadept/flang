// std.time.duration - amounts of time.
//
// `Duration` is exact elapsed time: a signed count of 100 ns ticks, the unit every std.time value
// counts in (C# TimeSpan, Python timedelta, Rust Duration). A day in a Duration is always 24 hours.
//
// `Period` is an amount on the calendar: years, months and days, each kept separately because none
// of them has a fixed length (Java and NodaTime Period, the date half of a Temporal Duration). One
// month after January 31 is February 28 or 29; one day after a DST change is 23 or 25 hours.
// Periods apply to dates (std.time.date) and wall-clock date-times (std.time.datetime), never to an
// Instant, which has no calendar.
//
// Both print and parse as ISO 8601 durations: a Duration as `PT26H3M4.5S` (hours are its largest
// unit), a Period as `P1Y2M3D`.

import std.format
import std.io.writer
import std.result
import std.string
import std.string_builder
import std.test
import std.time.calendar
import std.time.internal.common
import std.time.internal.parse

pub const TICKS_PER_MICROSECOND: i64 = 10
pub const TICKS_PER_MILLISECOND: i64 = 10000
pub const TICKS_PER_SECOND: i64 = 10000000
pub const TICKS_PER_MINUTE: i64 = 600000000
pub const TICKS_PER_HOUR: i64 = 36000000000
pub const TICKS_PER_DAY: i64 = 864000000000

// =============================================================================
// Duration
// =============================================================================

pub type Duration = struct {
    ticks: i64
}

// The longest durations either way, about 29,227 years. Symmetric, so negating either stays in
// range.
pub const MAX_DURATION: Duration = Duration { ticks = 9223372036854775807 }
pub const MIN_DURATION: Duration = Duration { ticks = -9223372036854775807 }

pub fn ticks(n: i64) Duration {
    return Duration { ticks = n }
}

// Truncates toward zero to whole ticks.
pub fn nanoseconds(n: i64) Duration {
    return Duration { ticks = n / 100 }
}

pub fn microseconds(n: i64) Duration {
    return Duration { ticks = scaled(n, TICKS_PER_MICROSECOND) }
}

pub fn milliseconds(n: i64) Duration {
    return Duration { ticks = scaled(n, TICKS_PER_MILLISECOND) }
}

pub fn seconds(n: i64) Duration {
    return Duration { ticks = scaled(n, TICKS_PER_SECOND) }
}

pub fn minutes(n: i64) Duration {
    return Duration { ticks = scaled(n, TICKS_PER_MINUTE) }
}

pub fn hours(n: i64) Duration {
    return Duration { ticks = scaled(n, TICKS_PER_HOUR) }
}

// Days of exactly 24 hours. For calendar days, use `period(days = n)`.
pub fn days(n: i64) Duration {
    return Duration { ticks = scaled(n, TICKS_PER_DAY) }
}

pub fn total_days(self: Duration) f64 {
    return self.ticks as f64 / TICKS_PER_DAY as f64
}

pub fn total_hours(self: Duration) f64 {
    return self.ticks as f64 / TICKS_PER_HOUR as f64
}

pub fn total_minutes(self: Duration) f64 {
    return self.ticks as f64 / TICKS_PER_MINUTE as f64
}

pub fn total_seconds(self: Duration) f64 {
    return self.ticks as f64 / TICKS_PER_SECOND as f64
}

pub fn total_milliseconds(self: Duration) f64 {
    return self.ticks as f64 / TICKS_PER_MILLISECOND as f64
}

pub fn abs(self: Duration) Duration {
    return if self.ticks < 0 { op_neg(self) } else { self }
}

pub fn op_add(a: Duration, b: Duration) Duration {
    return Duration { ticks = checked_add(a.ticks, b.ticks) }
}

pub fn op_sub(a: Duration, b: Duration) Duration {
    return Duration { ticks = checked_add(a.ticks, -b.ticks) }
}

pub fn op_neg(a: Duration) Duration {
    return Duration { ticks = -a.ticks }
}

pub fn mul(self: Duration, n: i64) Duration {
    return Duration { ticks = scaled(n, self.ticks) }
}

// Truncates toward zero to whole ticks.
pub fn div(self: Duration, n: i64) Duration {
    return Duration { ticks = self.ticks / n }
}

pub fn op_cmp(a: Duration, b: Duration) Ord {
    return op_cmp(a.ticks, b.ticks)
}

// ISO 8601, hours as the largest unit: `PT26H3M4.5S`, `-PT0.0000001S`, `PT0S`.
pub fn format(self: Duration, w: Writer, spec: String) {
    if self.ticks < 0 {
        w.write_byte('-')
    }
    const t = if self.ticks < 0 { -self.ticks } else { self.ticks }
    const h = t / TICKS_PER_HOUR
    const m = t % TICKS_PER_HOUR / TICKS_PER_MINUTE
    const s = t % TICKS_PER_MINUTE / TICKS_PER_SECOND
    const frac = t % TICKS_PER_SECOND
    w.write_str("PT")
    if h > 0 {
        w.write_int(h)
        w.write_byte('H')
    }
    if m > 0 {
        w.write_int(m)
        w.write_byte('M')
    }
    if s > 0 or frac > 0 or t == 0 {
        w.write_int(s)
        write_fraction(w, frac)
        w.write_byte('S')
    }
}

// Read an ISO 8601 duration of days, hours, minutes and seconds: `PT1H30M`, `P1DT12H`, `-PT0.5S`. A
// day reads as 24 hours. Years, months and weeks have no fixed length and are refused (BadFormat);
// they belong in a Period.
pub fn parse_duration(s: String) Result(Duration, TimeError) {
    let sc = scanner(s)
    const negative = sc.eat('-')
    if !sc.eat('P') {
        return Err(TimeError.BadFormat)
    }
    let total = 0i64
    let any = false
    if sc.peek() != 'T' {
        total = add_scaled(0, sc.number()?, TICKS_PER_DAY, 0)?
        if !sc.eat('D') {
            return Err(TimeError.BadFormat)
        }
        any = true
    }
    if sc.eat('T') {
        let units: u8[] = "HMS"
        let next_unit = 0usize
        while !sc.at_end() {
            const n = sc.number()?
            const frac = if sc.peek() == '.' { sc.fraction()? } else { 0i64 }
            const unit = sc.peek()
            let k = next_unit
            while k < units.len and units[k] != unit {
                k = k + 1
            }
            const is_seconds = k == 2
            if k == units.len or (frac != 0 and !is_seconds) {
                return Err(TimeError.BadFormat)
            }
            sc.skip()
            const scale = if k == 0 { TICKS_PER_HOUR } else if k == 1 { TICKS_PER_MINUTE } else { TICKS_PER_SECOND }
            total = add_scaled(total, n, scale, frac)?
            next_unit = k + 1
            any = true
        }
    }
    if !any or !sc.at_end() {
        return Err(TimeError.BadFormat)
    }
    return Ok(Duration { ticks = if negative { -total } else { total } })
}

// Every argument is non-negative. OutOfRange past MAX_DURATION.
fn add_scaled(total: i64, n: i64, scale: i64, frac: i64) Result(i64, TimeError) {
    const room = MAX_DURATION.ticks - total - frac
    if room < 0 or n > room / scale {
        return Err(TimeError.OutOfRange)
    }
    return Ok(total + n * scale + frac)
}

// =============================================================================
// Period
// =============================================================================

pub type Period = struct {
    years: i32
    months: i32
    days: i32
}

pub fn period(years: i32 = 0, months: i32 = 0, days: i32 = 0) Period {
    return Period { years, months, days }
}

pub fn op_add(a: Period, b: Period) Period {
    return Period {
        years = a.years + b.years,
        months = a.months + b.months,
        days = a.days + b.days,
    }
}

pub fn op_sub(a: Period, b: Period) Period {
    return Period {
        years = a.years - b.years,
        months = a.months - b.months,
        days = a.days - b.days,
    }
}

pub fn op_neg(a: Period) Period {
    return Period { years = -a.years, months = -a.months, days = -a.days }
}

// Field-wise: one year and twelve months are different periods, as they are in Java and Temporal.
pub fn op_eq(a: Period, b: Period) bool {
    return a.years == b.years and a.months == b.months and a.days == b.days
}

// ISO 8601: `P1Y2M3D`, each field signed on its own (`P-1M`), `P0D` when empty.
pub fn format(self: Period, w: Writer, spec: String) {
    w.write_byte('P')
    if self.years != 0 {
        w.write_int(self.years)
        w.write_byte('Y')
    }
    if self.months != 0 {
        w.write_int(self.months)
        w.write_byte('M')
    }
    if self.days != 0 or (self.years == 0 and self.months == 0) {
        w.write_int(self.days)
        w.write_byte('D')
    }
}

// Read an ISO 8601 period of years, months, weeks and days: `P1Y2M3D`, `P2W`, `-P1M`. A week reads
// as 7 days. A leading `-` negates every field; fields may also carry their own sign.
pub fn parse_period(s: String) Result(Period, TimeError) {
    let sc = scanner(s)
    const sign: i64 = if sc.eat('-') { -1 } else { 1 }
    if !sc.eat('P') or sc.at_end() {
        return Err(TimeError.BadFormat)
    }
    let units: u8[] = "YMWD"
    let fields = [0i64; 4]
    let next_unit = 0usize
    while !sc.at_end() {
        const field_sign: i64 = if sc.eat('-') { -1 } else { 1 }
        const n = sc.number()? * field_sign * sign
        let k = next_unit
        while k < units.len and units[k] != sc.peek() {
            k = k + 1
        }
        if k == units.len {
            return Err(TimeError.BadFormat)
        }
        sc.skip()
        fields[k] = n
        next_unit = k + 1
    }
    const days = fields[2] * 7 + fields[3]
    const fits = in_i32(fields[0]) and in_i32(fields[1]) and in_i32(days)
    if !fits {
        return Err(TimeError.OutOfRange)
    }
    return Ok(Period { years = fields[0] as i32, months = fields[1] as i32, days = days as i32 })
}

fn in_i32(n: i64) bool {
    return n >= -2147483648 and n <= 2147483647
}

test "duration constructors and totals" {
    assert_eq(hours(1).ticks, TICKS_PER_HOUR, "an hour")
    assert_eq(milliseconds(1500).total_seconds(), 1.5, "1.5 s")
    assert_eq(nanoseconds(250).ticks, 2i64, "truncates to ticks")
    assert_true(minutes(90) == hours(1) + minutes(30), "add")
    assert_true(op_neg(seconds(5)) < seconds(0), "negate and compare")
    assert_true(seconds(10).mul(3).div(2) == seconds(15), "scale")
    assert_true(seconds(-3).abs() == seconds(3), "abs")
}

test "duration bounds" {
    assert_true(op_neg(MAX_DURATION) == MIN_DURATION, "symmetric")
    assert_true(MIN_DURATION < ticks(0) and ticks(0) < MAX_DURATION, "ordered")
}

test "duration iso round trip" {
    const cases: String[] = ["PT0S", "PT26H3M4.5S", "-PT0.0000001S", "PT1M", "PT5H"]
    for c in cases {
        const d = parse_duration(c).unwrap()
        const text = $"{d}"
        defer text.deinit()
        assert_true(text.view == c, c)
    }
    assert_true(parse_duration("P1DT2H").unwrap() == hours(26), "days are 24 h")
    assert_true(parse_duration("PT1.5H").is_err(), "fraction only on seconds")
    assert_true(parse_duration("P1M").is_err(), "months refused")
    assert_true(parse_duration("PT1S1M").is_err(), "unit order")
    assert_true(parse_duration("P").is_err(), "empty")
    assert_true(
        parse_duration("P99999999999999999D").unwrap_err() == TimeError.OutOfRange,
        "overflow is an error",
    )
}

test "period format and parse" {
    const p = period(years = 1, months = 2, days = 3)
    const text = $"{p}"
    defer text.deinit()
    assert_true(text.view == "P1Y2M3D", "format")
    assert_true(parse_period("P1Y2M3D").unwrap() == p, "parse")
    assert_true(parse_period("P2W").unwrap() == period(days = 14), "weeks")
    assert_true(parse_period("-P1M").unwrap() == period(months = -1), "negated")
    assert_true(parse_period("P0D").unwrap() == period(), "zero")
    assert_true(parse_period("P1D1Y").is_err(), "unit order")
    assert_true(op_neg(p) + p == period(), "negate")
}
