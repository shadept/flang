// std.time.calendar - the proleptic Gregorian calendar, the only calendar std.time knows.
//
// Days are counted from the Unix epoch, 1970-01-01, as "epoch days": day 0 is 1970-01-01, day -1 is
// 1969-12-31. Every date type stores one. Years run from MIN_YEAR to MAX_YEAR, the ISO 8601
// extended range. Year 0 exists and is 1 BC, as ISO 8601 has it.
//
// `Month` and `Weekday` are plain integer enums: `Month.March as i32` is 3, `3 as Month` is March,
// and `Weekday` numbers Monday 1 through Sunday 7 as ISO 8601 does.

import std.format
import std.io.writer
import std.test

pub const MIN_YEAR: i32 = -9999
pub const MAX_YEAR: i32 = 9999

// Epoch days of -9999-01-01 and 9999-12-31.
pub const MIN_EPOCH_DAY: i64 = -4371587
pub const MAX_EPOCH_DAY: i64 = 2932896

pub type Month = enum {
    January = 1
    February = 2
    March = 3
    April = 4
    May = 5
    June = 6
    July = 7
    August = 8
    September = 9
    October = 10
    November = 11
    December = 12
}

pub type Weekday = enum {
    Monday = 1
    Tuesday = 2
    Wednesday = 3
    Thursday = 4
    Friday = 5
    Saturday = 6
    Sunday = 7
}

// Why a date, time, offset or zone could not be built or parsed.
pub type TimeError = enum {
    // A field outside its calendar range: day 30 of February, hour 24.
    InvalidDate
    InvalidTime
    // A UTC offset of a day or more.
    InvalidOffset
    // A valid calendar value outside MIN_YEAR..MAX_YEAR.
    OutOfRange
    // Text that is not the format the parser reads.
    BadFormat
    UnknownZone
    // The system carries no time zone database.
    ZoneDataUnavailable
}

pub fn is_leap_year(year: i32) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
}

pub fn days_in_year(year: i32) i32 {
    return if is_leap_year(year) { 366 } else { 365 }
}

pub fn days_in_month(year: i32, month: Month) i32 {
    return month match {
        February => if is_leap_year(year) { 29 } else { 28 }
        April | June | September | November => 30
        else => 31
    }
}

// Epoch days of a calendar date. The fields are not validated: day 0 is the last day of the
// previous month, as `date` would refuse.
pub fn days_from_civil(year: i32, month: Month, day: i32) i64 {
    // Howard Hinnant's algorithm: years start in March, so the leap day falls at the end.
    const m = month as i64
    const y = year as i64 - (if m <= 2 { 1 } else { 0 })
    const era = div_floor(y, 400i64)
    const year_of_era = y - era * 400
    const month_from_march = if m > 2 { m - 3 } else { m + 9 }
    const day_of_year = (153 * month_from_march + 2) / 5 + day as i64 - 1
    const day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year
    return era * 146097 + day_of_era - 719468
}

// The calendar date of an epoch day, as (year, month, day).
pub fn civil_from_days(epoch_day: i64) (i32, Month, i32) {
    const z = epoch_day + 719468
    const era = div_floor(z, 146097i64)
    const day_of_era = z - era * 146097
    const year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365
    const day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
    const month_from_march = (5 * day_of_year + 2) / 153
    const day = day_of_year - (153 * month_from_march + 2) / 5 + 1
    const month = if month_from_march < 10 { month_from_march + 3 } else { month_from_march - 9 }
    const year = year_of_era + era * 400 + (if month <= 2 { 1 } else { 0 })
    return (year as i32, month as i32 as Month, day as i32)
}

pub fn weekday_from_days(epoch_day: i64) Weekday {
    // 1970-01-01 was a Thursday.
    return (mod_floor(epoch_day + 3, 7i64) + 1) as i32 as Weekday
}

pub fn name(self: Month) String {
    return self match {
        January => "January"
        February => "February"
        March => "March"
        April => "April"
        May => "May"
        June => "June"
        July => "July"
        August => "August"
        September => "September"
        October => "October"
        November => "November"
        December => "December"
    }
}

pub fn name(self: Weekday) String {
    return self match {
        Monday => "Monday"
        Tuesday => "Tuesday"
        Wednesday => "Wednesday"
        Thursday => "Thursday"
        Friday => "Friday"
        Saturday => "Saturday"
        Sunday => "Sunday"
    }
}

pub fn format(self: Month, w: Writer, spec: String) {
    self.name().format(w, spec)
}

pub fn format(self: Weekday, w: Writer, spec: String) {
    self.name().format(w, spec)
}

pub fn format(self: TimeError, w: Writer, spec: String) {
    const text = self match {
        InvalidDate => "invalid date"
        InvalidTime => "invalid time"
        InvalidOffset => "invalid UTC offset"
        OutOfRange => "outside years -9999..9999"
        BadFormat => "bad format"
        UnknownZone => "unknown time zone"
        ZoneDataUnavailable => "no time zone data on this system"
    }
    text.format(w, spec)
}

test "civil round trip across eras" {
    assert_eq(days_from_civil(1970, Month.January, 1), 0i64, "epoch")
    assert_eq(days_from_civil(2000, Month.March, 1), 11017i64, "2000-03-01")
    assert_eq(days_from_civil(1, Month.January, 1), -719162i64, "0001-01-01")
    assert_eq(days_from_civil(MIN_YEAR, Month.January, 1), MIN_EPOCH_DAY, "min")
    assert_eq(days_from_civil(MAX_YEAR, Month.December, 31), MAX_EPOCH_DAY, "max")
    for d in [-4371587i64, -719162i64, -1i64, 0i64, 59i64, 11016i64, 2932896i64] {
        const ymd = civil_from_days(d)
        assert_eq(days_from_civil(ymd.0, ymd.1, ymd.2), d, "round trip")
    }
}

test "leap years and month lengths" {
    assert_true(is_leap_year(2000), "2000")
    assert_true(!is_leap_year(1900), "1900")
    assert_true(is_leap_year(2024), "2024")
    assert_true(is_leap_year(0), "year 0")
    assert_true(is_leap_year(-4), "-4")
    assert_eq(days_in_month(2024, Month.February), 29i32, "Feb 2024")
    assert_eq(days_in_month(2023, Month.February), 28i32, "Feb 2023")
    assert_eq(days_in_month(2023, Month.April), 30i32, "April")
}

test "weekdays" {
    assert_true(weekday_from_days(0) == Weekday.Thursday, "epoch")
    assert_true(weekday_from_days(-1) == Weekday.Wednesday, "day before epoch")
    assert_true(
        weekday_from_days(days_from_civil(2026, Month.October, 14)) == Weekday.Wednesday,
        "today",
    )
    assert_eq(Month.March as i32, 3i32, "month to int")
    assert_true(12i32 as Month == Month.December, "int to month")
}
