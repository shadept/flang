// std.time.internal.common - what the std.time modules share and do not export: checked tick
// arithmetic and the writers behind every `format`.
//
// Pattern specs are a strftime subset, decided here once for every type:
//
//   %Y year (4 digits, or signed 6 outside 0..9999)   %y year 00-99   %m month 01-12
//   %d day 01-31   %e day 1-31   %H hour 00-23   %I hour 01-12   %p AM or PM
//   %M minute 00-59   %S second 00-59   %f microseconds 000000-999999
//   %j day of year 001-366   %u ISO weekday 1-7   %V ISO week 01-53   %G ISO week year
//   %a %A weekday name, short and full   %b %B month name, short and full
//   %z UTC offset +hhmm (nothing when the value has none)   %F = %Y-%m-%d   %T = %H:%M:%S
//   %% a literal %
//
// Any other `%x` is written as is. Names are English. std.time.internal.parse reads the same codes
// back.

import std.io.writer
import std.result
import std.time.calendar
import std.time.date
import std.time.datetime
import std.time.duration
import std.time.time

// =============================================================================
// Checked tick arithmetic
// =============================================================================

pub fn out_of_range() never {
    panic("std.time: value outside years -9999..9999")
}

pub fn checked_add(a: i64, b: i64) i64 {
    const r = a + b
    const same_sign = (a < 0) == (b < 0)
    if same_sign and (r < 0) != (a < 0) {
        out_of_range()
    }
    return r
}

pub fn scaled(n: i64, unit: i64) i64 {
    if n == 0 or unit == 0 {
        return 0
    }
    if n == -1 {
        return checked_add(0, -unit)
    }
    const r = n * unit
    if r / n != unit {
        out_of_range()
    }
    return r
}

// `ticks` when it lies in MIN_YEAR..MAX_YEAR, OutOfRange otherwise.
pub fn in_range(ticks: i64) Result(i64, TimeError) {
    const first = MIN_EPOCH_DAY * TICKS_PER_DAY
    const last = (MAX_EPOCH_DAY + 1) * TICKS_PER_DAY - 1
    if ticks < first or ticks > last {
        return Err(TimeError.OutOfRange)
    }
    return Ok(ticks)
}

// The UTC ticks of `dt` read at `offset` seconds east; OutOfRange past MIN_YEAR..MAX_YEAR in UTC.
pub fn utc_ticks(dt: DateTime, offset: i32) Result(i64, TimeError) {
    return in_range(dt.ticks - offset as i64 * TICKS_PER_SECOND)
}

// =============================================================================
// Writers
// =============================================================================

pub fn write_padded(w: Writer, n: i64, width: i32) {
    let digits = 1
    let rest = n / 10
    while rest > 0 {
        digits = digits + 1
        rest = rest / 10
    }
    for _k in digits..width {
        w.write_byte('0')
    }
    w.write_int(n)
}

pub fn write_year(w: Writer, year: i32) {
    if year >= 0 and year <= 9999 {
        write_padded(w, year as i64, 4)
        return
    }
    w.write_byte(if year < 0 { '-' } else { '+' })
    write_padded(w, if year < 0 { -year as i64 } else { year as i64 }, 6)
}

// The sub-second ticks as `.5`, `.0000001`: trailing zeros trimmed, nothing at all for zero.
pub fn write_fraction(w: Writer, frac_ticks: i64) {
    if frac_ticks == 0 {
        return
    }
    let digits = 7
    let f = frac_ticks
    while f % 10 == 0 {
        f = f / 10
        digits = digits - 1
    }
    w.write_byte('.')
    write_padded(w, f, digits)
}

// `+hh:mm`, or `+hhmm` without the colon; seconds only when the offset has them.
pub fn write_offset(w: Writer, seconds: i32, colon: bool) {
    w.write_byte(if seconds < 0 { '-' } else { '+' })
    const s = if seconds < 0 { -seconds } else { seconds }
    write_padded(w, (s / 3600) as i64, 2)
    if colon {
        w.write_byte(':')
    }
    write_padded(w, (s % 3600 / 60) as i64, 2)
    if s % 60 != 0 {
        if colon {
            w.write_byte(':')
        }
        write_padded(w, (s % 60) as i64, 2)
    }
}

pub fn write_date(w: Writer, d: Date) {
    write_year(w, d.year())
    w.write_byte('-')
    write_padded(w, d.month() as i64, 2)
    w.write_byte('-')
    write_padded(w, d.day() as i64, 2)
}

pub fn write_time(w: Writer, t: Time) {
    write_padded(w, t.hour() as i64, 2)
    w.write_byte(':')
    write_padded(w, t.minute() as i64, 2)
    w.write_byte(':')
    write_padded(w, t.second() as i64, 2)
    write_fraction(w, t.ticks % TICKS_PER_SECOND)
}

// Expand a strftime-style `pattern` (see the module header) for a date at a time, with an offset
// when the value carries one.
pub fn write_pattern(w: Writer, d: Date, t: Time, offset: i32?, pattern: String) {
    let i = 0usize
    while i < pattern.len {
        const c = pattern[i]
        if c != '%' or i + 1 == pattern.len {
            w.write_byte(c)
            i = i + 1
            continue
        }
        write_field(w, d, t, offset, pattern[i + 1])
        i = i + 2
    }
}

fn write_field(w: Writer, d: Date, t: Time, offset: i32?, field: u8) {
    if field == 'Y' {
        write_year(w, d.year())
    }
    else if field == 'm' {
        write_padded(w, d.month() as i64, 2)
    }
    else if field == 'y' {
        write_padded(w, mod_floor(d.year(), 100) as i64, 2)
    }
    else if field == 'd' {
        write_padded(w, d.day() as i64, 2)
    }
    else if field == 'e' {
        w.write_int(d.day())
    }
    else if field == 'H' {
        write_padded(w, t.hour() as i64, 2)
    }
    else if field == 'I' {
        const h = t.hour() % 12
        write_padded(w, if h == 0 { 12i64 } else { h as i64 }, 2)
    }
    else if field == 'p' {
        w.write_str(if t.hour() < 12 { "AM" } else { "PM" })
    }
    else if field == 'M' {
        write_padded(w, t.minute() as i64, 2)
    }
    else if field == 'S' {
        write_padded(w, t.second() as i64, 2)
    }
    else if field == 'f' {
        write_padded(w, t.ticks % TICKS_PER_SECOND / TICKS_PER_MICROSECOND, 6)
    }
    else if field == 'j' {
        write_padded(w, d.day_of_year() as i64, 3)
    }
    else if field == 'u' {
        w.write_int(d.weekday() as i32)
    }
    else if field == 'V' {
        write_padded(w, d.iso_week().1 as i64, 2)
    }
    else if field == 'G' {
        write_year(w, d.iso_week().0)
    }
    else if field == 'a' {
        w.write_str(d.weekday().name()[0..3])
    }
    else if field == 'A' {
        w.write_str(d.weekday().name())
    }
    else if field == 'b' {
        w.write_str(d.month().name()[0..3])
    }
    else if field == 'B' {
        w.write_str(d.month().name())
    }
    else if field == 'z' {
        offset match {
            Some(o) => write_offset(w, o, false)
            None => {}
        }
    }
    else if field == 'F' {
        write_pattern(w, d, t, offset, "%Y-%m-%d")
    }
    else if field == 'T' {
        write_pattern(w, d, t, offset, "%H:%M:%S")
    }
    else if field == '%' {
        w.write_byte('%')
    }
    else {
        w.write_byte('%')
        w.write_byte(field)
    }
}
