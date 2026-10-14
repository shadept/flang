// Dates, times, durations, time zones and clocks, through one import. Modelled on C# (DateOnly,
// TimeOnly, TimeSpan, DateTimeOffset), Temporal (Instant, PlainDateTime), Python and Rust; every
// value counts 100 ns ticks, as C# does.
//
//   Instant         a point on the timeline, UTC                     std.time.instant
//   DateTime        a calendar date and wall-clock time, no zone     std.time.datetime
//   Date, Time      either half of a DateTime                        std.time.date, std.time.time
//   OffsetDateTime  an Instant and the UTC offset it was read at     std.time.zone
//   TimeZone        UTC, a fixed offset, or an IANA zone             std.time.zone
//   Duration        exact elapsed time                               std.time.duration
//   Period          years, months and days on the calendar           std.time.duration
//   Month, Weekday  integer enums, and the calendar arithmetic       std.time.calendar
//
// Formatting writes ISO 8601 / RFC 3339 by default, or a strftime pattern: `$"{d:%d %B %Y}"`.
//
// Every parser reads the whole string and returns Result(T, TimeError). The one-argument parsers
// read ISO 8601 only:
//
//   parse_date             2026-10-14, +012026-10-14, -000044-03-15
//   parse_time             13:45, 13:45:30, 13:45:30.1234567
//   parse_datetime         date, then T, t or a space, then time; a date alone is midnight; no offset
//   parse_instant          RFC 3339: date, time and offset, ...Z, ...+01:00, ...-0500
//   parse_offset_datetime  as parse_instant, keeping the offset
//   parse_duration         PT1H30M, P1DT12H, -PT0.5S (a day is 24 hours; Y, M, W refused)
//   parse_period           P1Y2M3D, P2W, -P1M (a week is 7 days)
//
// Other text:
//
//   parse_offset_datetime(s, tz), parse_instant(s, tz)
//       any ISO 8601 date or date-time, offset or not; without one it is wall-clock time in `tz`
//       (TimeZone.Utc, or `system_zone()?` for local time)
//   parse_date / parse_time / parse_datetime / parse_offset_datetime / parse_instant (s, pattern)
//       the strftime codes `format` writes, read back: parse_date("4/7/2026", "%d/%m/%Y");
//       parse_offset_datetime(s, pattern, tz) falls back to `tz` when the text has no zone
//   parse_rfc5322    email and HTTP dates: Tue, 14 Oct 2026 09:30:00 +0100
//   parse_zone       a zone field: UTC, +01:00, UTC+1, EST, Europe/Lisbon
//
// Pattern rules are in std.time.internal.parse. Seconds take a fraction after `.` or `,`, up to 9
// digits; digits past the 7th (100 ns) are dropped. A leap second (:60) reads as :59. Errors:
// BadFormat for text of the wrong shape, InvalidDate / InvalidTime / InvalidOffset for a field out
// of range, OutOfRange for a value past years -9999..9999 (in UTC for an instant) or a Duration or
// Period field too large, UnknownZone for a zone name the database lacks.

pub import std.time.calendar
pub import std.time.clock
pub import std.time.date
pub import std.time.datetime
pub import std.time.duration
pub import std.time.instant
pub import std.time.stopwatch
pub import std.time.time
pub import std.time.zone
