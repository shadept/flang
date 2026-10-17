// std.time.internal.parse - the readers behind every parser: the scanner, ISO 8601, patterns
// (`parse_date(s, pattern)` and its siblings) and RFC 5322 dates. Pattern and RFC 5322 readers
// collect what the text says into `Fields`, which the public parsers turn into the type they
// return.
//
// A pattern reads back the codes `format` writes (std.time.internal.common), plus `%Z`:
//
//   %Y 4 digits, or a sign and 1 to 6   %y 1 or 2 digits, 69-99 -> 19xx and 00-68 -> 20xx (POSIX)
//   %m %d %e %H %I %M %S 1 or 2 digits   %j 1 to 3 digits   %u 1 digit   %f 1 to 9 digits
//   %a %A a weekday, %b %B a month: the full or 3-letter English name, any case   %p AM or PM
//   %z Z, UTC, GMT, UT, or +hh, +hhmm, +hh:mm, +hh:mm:ss
//   %Z a zone field up to the next space, read by parse_zone   %F %T %% as `format` writes them
//
// A space matches one or more spaces or tabs; any other byte matches itself. %V and %G are refused
// (BadFormat). Time fields the pattern leaves out are 0; %I without %p is AM. A second of 60 reads
// as 59. A weekday or day of year that contradicts the date is InvalidDate.

import std.option
import std.result
import std.string
import std.time.calendar
import std.time.date
import std.time.datetime
import std.time.duration
import std.time.time
import std.time.zone

pub type Fields = struct {
    year: i32?
    month: i32?
    day: i32?
    day_of_year: i32?
    weekday: i32?
    hour: i32?
    hour12: i32?
    pm: bool
    minute: i32
    second: i32
    frac: i64
    offset: i32?
    zone: TimeZone?
}

fn fields() Fields {
    return Fields {
        year = null,
        month = null,
        day = null,
        day_of_year = null,
        weekday = null,
        hour = null,
        hour12 = null,
        pm = false,
        minute = 0,
        second = 0,
        frac = 0,
        offset = null,
        zone = null,
    }
}

// =============================================================================
// Scanner
// =============================================================================

pub type Scanner = struct {
    s: String
    pos: usize
}

pub fn scanner(s: String) Scanner {
    return Scanner { s, pos = 0 }
}

pub fn at_end(self: &Scanner) bool {
    return self.pos >= self.s.len
}

// The next byte, 0 at the end.
pub fn peek(self: &Scanner) u8 {
    return if self.at_end() { 0 } else { self.s[self.pos] }
}

pub fn skip(self: &Scanner) {
    self.pos = self.pos + 1
}

pub fn eat(self: &Scanner, c: u8) bool {
    if self.at_end() or self.s[self.pos] != c {
        return false
    }
    self.pos = self.pos + 1
    return true
}

fn is_digit_at(self: &Scanner) bool {
    const c = self.peek()
    return c >= '0' and c <= '9'
}

pub fn is_letter_at(self: &Scanner) bool {
    const c = self.peek()
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')
}

fn is_blank_at(self: &Scanner) bool {
    const c = self.peek()
    return c == ' ' or c == '\t'
}

// Consume `word` if the input continues with it, in any ASCII case.
pub fn eat_word(self: &Scanner, word: String) bool {
    const end = self.pos + word.len
    if end > self.s.len or !eq_ignore_ascii_case(self.s[self.pos..end], word) {
        return false
    }
    self.pos = end
    return true
}

// The run of ASCII letters at the cursor, possibly empty.
pub fn letters(self: &Scanner) String {
    const start = self.pos
    while self.is_letter_at() {
        self.pos = self.pos + 1
    }
    return self.s[start..self.pos]
}

// Everything up to the next space or tab, or the end.
pub fn word(self: &Scanner) String {
    const start = self.pos
    while !self.at_end() and !self.is_blank_at() {
        self.pos = self.pos + 1
    }
    return self.s[start..self.pos]
}

// Skip spaces and tabs; false when there were none.
pub fn skip_blanks(self: &Scanner) bool {
    const start = self.pos
    while self.is_blank_at() {
        self.pos = self.pos + 1
    }
    return self.pos > start
}

// Exactly `n` decimal digits.
pub fn digits(self: &Scanner, n: usize) Result(i64, TimeError) {
    let value = 0i64
    for _k in 0..n {
        if !self.is_digit_at() {
            return Err(TimeError.BadFormat)
        }
        value = value * 10 + (self.peek() - '0') as i64
        self.pos = self.pos + 1
    }
    return Ok(value)
}

// One to `n` decimal digits.
pub fn up_to(self: &Scanner, n: usize) Result(i64, TimeError) {
    const start = self.pos
    let value = 0i64
    while self.pos - start < n and self.is_digit_at() {
        value = value * 10 + (self.peek() - '0') as i64
        self.pos = self.pos + 1
    }
    if self.pos == start {
        return Err(TimeError.BadFormat)
    }
    return Ok(value)
}

// One to eighteen decimal digits.
pub fn number(self: &Scanner) Result(i64, TimeError) {
    let value = 0i64
    let count = 0i32
    while self.is_digit_at() {
        if count == 18 {
            return Err(TimeError.OutOfRange)
        }
        value = value * 10 + (self.peek() - '0') as i64
        self.pos = self.pos + 1
        count = count + 1
    }
    if count == 0 {
        return Err(TimeError.BadFormat)
    }
    return Ok(value)
}

// A decimal fraction of a second (`.5`, `,25`, up to nine digits) as ticks, truncated past the
// seventh digit.
pub fn fraction(self: &Scanner) Result(i64, TimeError) {
    if !self.eat('.') and !self.eat(',') {
        return Err(TimeError.BadFormat)
    }
    return self.fraction_digits()
}

// The digits of a fraction of a second, without its separator; see `fraction`.
pub fn fraction_digits(self: &Scanner) Result(i64, TimeError) {
    let ticks = 0i64
    let count = 0i32
    while self.is_digit_at() {
        if count == 9 {
            return Err(TimeError.BadFormat)
        }
        if count < 7 {
            ticks = ticks * 10 + (self.peek() - '0') as i64
        }
        self.pos = self.pos + 1
        count = count + 1
    }
    if count == 0 {
        return Err(TimeError.BadFormat)
    }
    for _k in count..7 {
        ticks = ticks * 10
    }
    return Ok(ticks)
}

// =============================================================================
// ISO 8601
// =============================================================================

// `YYYY-MM-DD`, or `+YYYYYY-MM-DD` or `-YYYYYY-MM-DD` for any year; `-000000` is refused, as ISO
// 8601 does.
pub fn scan_date(self: &Scanner) Result(Date, TimeError) {
    let year = 0i64
    const c = self.peek()
    if c == '+' or c == '-' {
        self.skip()
        year = self.digits(6)?
        if c == '-' {
            if year == 0 {
                return Err(TimeError.BadFormat)
            }
            year = -year
        }
    }
    else {
        year = self.digits(4)?
    }
    if !self.eat('-') {
        return Err(TimeError.BadFormat)
    }
    const month = self.digits(2)?
    if !self.eat('-') {
        return Err(TimeError.BadFormat)
    }
    const day = self.digits(2)?
    if month < 1 or month > 12 {
        return Err(TimeError.InvalidDate)
    }
    if year < MIN_YEAR as i64 or year > MAX_YEAR as i64 {
        return Err(TimeError.OutOfRange)
    }
    return date(year as i32, month as i32 as Month, day as i32)
}

// `HH:MM`, `HH:MM:SS` or `HH:MM:SS.fffffff`. A leap second `:60` reads as `:59`, as Temporal does.
pub fn scan_time(self: &Scanner) Result(Time, TimeError) {
    const hour = self.digits(2)?
    if !self.eat(':') {
        return Err(TimeError.BadFormat)
    }
    const minute = self.digits(2)?
    let second = 0i64
    let frac = 0i64
    if self.eat(':') {
        second = self.digits(2)?
        if second == 60 {
            second = 59
        }
        const c = self.peek()
        if c == '.' or c == ',' {
            frac = self.fraction()?
        }
    }
    const t = time(hour as i32, minute as i32, second as i32)?
    return Ok(t + ticks(frac))
}

fn eat_separator(self: &Scanner) bool {
    return self.eat('T') or self.eat('t') or self.eat(' ')
}

// A date, then optionally `T`, `t` or a space and a time; a date alone is its midnight.
pub fn scan_datetime(self: &Scanner) Result(DateTime, TimeError) {
    const d = self.scan_date()?
    if self.eat_separator() {
        return Ok(datetime(d, self.scan_time()?))
    }
    return Ok(datetime(d, Time { ticks = 0 }))
}

// An RFC 3339 timestamp, the whole input: a date, a separator, a time and an offset.
pub fn scan_timestamp(self: &Scanner) Result((DateTime, i32), TimeError) {
    const d = self.scan_date()?
    if !self.eat_separator() {
        return Err(TimeError.BadFormat)
    }
    const t = self.scan_time()?
    const offset = self.scan_offset()?
    if !self.at_end() {
        return Err(TimeError.BadFormat)
    }
    return Ok((datetime(d, t), offset))
}

// `Z`, or a sign then `HH`, `HHMM`, `HH:MM` or `HH:MM:SS`, as seconds east of UTC.
pub fn scan_offset(self: &Scanner) Result(i32, TimeError) {
    if self.eat('Z') or self.eat('z') {
        return Ok(0)
    }
    const c = self.peek()
    if c != '+' and c != '-' {
        return Err(TimeError.BadFormat)
    }
    self.skip()
    const hours = self.digits(2)?
    return self.offset_tail(c, hours)
}

// A sign then `H`, `HH`, `HHMM`, `H:MM`, `HH:MM` or `HH:MM:SS`, as seconds east of UTC.
pub fn scan_loose_offset(self: &Scanner) Result(i32, TimeError) {
    const c = self.peek()
    if c != '+' and c != '-' {
        return Err(TimeError.BadFormat)
    }
    self.skip()
    const hours = self.up_to(2)?
    return self.offset_tail(c, hours)
}

fn offset_tail(self: &Scanner, sign: u8, hours: i64) Result(i32, TimeError) {
    let minutes = 0i64
    let seconds = 0i64
    if self.eat(':') {
        minutes = self.digits(2)?
        if self.eat(':') {
            seconds = self.digits(2)?
        }
    }
    else if self.is_digit_at() {
        minutes = self.digits(2)?
    }
    if hours > 23 or minutes > 59 or seconds > 59 {
        return Err(TimeError.InvalidOffset)
    }
    const total = (hours * 3600 + minutes * 60 + seconds) as i32
    return Ok(if sign == '-' { -total } else { total })
}

// Seconds east of UTC for a zone name RFC 5322 defines, in any case: UT, GMT, and the North
// American EST, EDT, CST, CDT, MST, MDT, PST and PDT.
pub fn rfc5322_zone(name: String) i32? {
    const names = ["UT", "GMT", "EST", "EDT", "CST", "CDT", "MST", "MDT", "PST", "PDT"]
    const hours = [0i32, 0i32, -5i32, -4i32, -6i32, -5i32, -7i32, -6i32, -8i32, -7i32]
    for i in 0..names.len {
        if eq_ignore_ascii_case(name, names[i]) {
            return Some(hours[i] * 3600)
        }
    }
    return null
}

// =============================================================================
// Patterns
// =============================================================================

// The fields `pattern` finds in the whole of `s`.
pub fn read_pattern(s: String, pattern: String) Result(Fields, TimeError) {
    let sc = scanner(s)
    let f = fields()
    sc.read_fields(&f, pattern)?
    if !sc.at_end() {
        return Err(TimeError.BadFormat)
    }
    return Ok(f)
}

fn read_fields(self: &Scanner, f: &Fields, pattern: String) Result((), TimeError) {
    let i = 0usize
    while i < pattern.len {
        const c = pattern[i]
        const is_code = c == '%' and i + 1 < pattern.len
        if is_code {
            self.read_field(f, pattern[i + 1])?
            i = i + 2
            continue
        }
        const matched = if c == ' ' { self.skip_blanks() } else { self.eat(c) }
        if !matched {
            return Err(TimeError.BadFormat)
        }
        i = i + 1
    }
    return Ok(())
}

fn read_field(self: &Scanner, f: &Fields, code: u8) Result((), TimeError) {
    if code == 'Y' {
        f.year = Some(self.read_year()?)
    }
    else if code == 'y' {
        const yy = self.up_to(2)? as i32
        f.year = Some(if yy >= 69 { 1900 + yy } else { 2000 + yy })
    }
    else if code == 'm' {
        f.month = Some(self.up_to(2)? as i32)
    }
    else if code == 'd' or code == 'e' {
        f.day = Some(self.up_to(2)? as i32)
    }
    else if code == 'H' {
        f.hour = Some(self.up_to(2)? as i32)
    }
    else if code == 'I' {
        f.hour12 = Some(self.up_to(2)? as i32)
    }
    else if code == 'M' {
        f.minute = self.up_to(2)? as i32
    }
    else if code == 'S' {
        f.second = self.up_to(2)? as i32
    }
    else if code == 'f' {
        f.frac = self.fraction_digits()?
    }
    else if code == 'j' {
        f.day_of_year = Some(self.up_to(3)? as i32)
    }
    else if code == 'u' {
        f.weekday = Some(self.up_to(1)? as i32)
    }
    else if code == 'a' or code == 'A' {
        f.weekday = Some(self.read_weekday()?)
    }
    else if code == 'b' or code == 'B' {
        f.month = Some(self.read_month()?)
    }
    else if code == 'p' {
        f.pm = self.read_meridiem()?
    }
    else if code == 'z' {
        f.offset = Some(self.read_offset()?)
    }
    else if code == 'Z' {
        f.zone = Some(parse_zone(self.word())?)
    }
    else if code == 'F' {
        return self.read_fields(f, "%Y-%m-%d")
    }
    else if code == 'T' {
        return self.read_fields(f, "%H:%M:%S")
    }
    else if code != '%' or !self.eat('%') {
        return Err(TimeError.BadFormat)
    }
    return Ok(())
}

fn read_year(self: &Scanner) Result(i32, TimeError) {
    const c = self.peek()
    if c != '+' and c != '-' {
        return Ok(self.digits(4)? as i32)
    }
    self.skip()
    const year = self.up_to(6)? as i32
    return Ok(if c == '-' { -year } else { year })
}

// 1 for January; the full name is tried before the 3-letter one.
fn read_month(self: &Scanner) Result(i32, TimeError) {
    for m in 1i32..13i32 {
        const name = (m as Month).name()
        if self.eat_word(name) or self.eat_word(name[0..3]) {
            return Ok(m)
        }
    }
    return Err(TimeError.BadFormat)
}

// 1 for Monday.
fn read_weekday(self: &Scanner) Result(i32, TimeError) {
    for d in 1i32..8i32 {
        const name = (d as Weekday).name()
        if self.eat_word(name) or self.eat_word(name[0..3]) {
            return Ok(d)
        }
    }
    return Err(TimeError.BadFormat)
}

// True for PM.
fn read_meridiem(self: &Scanner) Result(bool, TimeError) {
    if self.eat_word("AM") {
        return Ok(false)
    }
    if self.eat_word("PM") {
        return Ok(true)
    }
    return Err(TimeError.BadFormat)
}

fn read_offset(self: &Scanner) Result(i32, TimeError) {
    if self.eat_word("UTC") or self.eat_word("GMT") or self.eat_word("UT") {
        return Ok(0)
    }
    return self.scan_offset()
}

// =============================================================================
// RFC 5322
// =============================================================================

// The fields of an RFC 5322 date-time, the whole of `s`; see parse_rfc5322 (std.time.zone).
pub fn read_rfc5322(s: String) Result(Fields, TimeError) {
    let sc = scanner(s)
    let f = fields()
    sc.skip_cfws()?
    if sc.is_letter_at() {
        f.weekday = Some(sc.read_weekday()?)
        sc.skip_cfws()?
        if !sc.eat(',') {
            return Err(TimeError.BadFormat)
        }
        sc.skip_cfws()?
    }
    f.day = Some(sc.up_to(2)? as i32)
    sc.skip_cfws()?
    f.month = Some(sc.read_month()?)
    sc.skip_cfws()?
    f.year = Some(sc.rfc5322_year()?)
    sc.skip_cfws()?
    f.hour = Some(sc.up_to(2)? as i32)
    sc.expect_colon()?
    f.minute = sc.up_to(2)? as i32
    sc.skip_cfws()?
    if sc.eat(':') {
        sc.skip_cfws()?
        f.second = sc.up_to(2)? as i32
        sc.skip_cfws()?
    }
    f.offset = Some(sc.rfc5322_offset()?)
    sc.skip_cfws()?
    if !sc.at_end() {
        return Err(TimeError.BadFormat)
    }
    return Ok(f)
}

fn expect_colon(self: &Scanner) Result((), TimeError) {
    self.skip_cfws()?
    if !self.eat(':') {
        return Err(TimeError.BadFormat)
    }
    return self.skip_cfws()
}

// Whitespace, line folds and parenthesised comments, which nest and may escape with `\`.
fn skip_cfws(self: &Scanner) Result((), TimeError) {
    let depth = 0i32
    while !self.at_end() {
        const c = self.peek()
        const is_space = c == ' ' or c == '\t' or c == '\r' or c == '\n'
        if c == '(' {
            depth = depth + 1
        }
        else if c == ')' and depth > 0 {
            depth = depth - 1
        }
        else if c == '\\' and depth > 0 {
            self.skip()
        }
        else if !is_space and depth == 0 {
            return Ok(())
        }
        self.skip()
    }
    if depth > 0 {
        return Err(TimeError.BadFormat)
    }
    return Ok(())
}

// Four or more digits as written; the obsolete 2-digit years are 1950-2049, 3-digit ones 1900 on.
fn rfc5322_year(self: &Scanner) Result(i32, TimeError) {
    const start = self.pos
    const n = self.number()? as i32
    const len = self.pos - start
    if len == 2 {
        return Ok(if n < 50 { 2000 + n } else { 1900 + n })
    }
    if len == 3 {
        return Ok(1900 + n)
    }
    if len < 2 {
        return Err(TimeError.BadFormat)
    }
    return Ok(n)
}

// `+hhmm`, a zone name RFC 5322 defines, or UTC. A single military letter reads as +00:00: the RFC
// calls their meaning unreliable.
fn rfc5322_offset(self: &Scanner) Result(i32, TimeError) {
    const c = self.peek()
    if c == '+' or c == '-' {
        return self.scan_offset()
    }
    const name = self.letters()
    if name.len == 1 or eq_ignore_ascii_case(name, "UTC") {
        return Ok(0)
    }
    return rfc5322_zone(name) match {
        Some(offset) => Ok(offset)
        None => Err(TimeError.BadFormat)
    }
}

// =============================================================================
// Fields to values
// =============================================================================

// BadFormat without a year, and without a month and day or a day of year.
pub fn to_date(self: Fields) Result(Date, TimeError) {
    const year = self.year match {
        Some(y) => y
        None => return Err(TimeError.BadFormat)
    }
    const d = self.calendar_date(year)?
    const doy_matches = self.day_of_year match {
        Some(n) => d.day_of_year() == n
        None => true
    }
    const weekday_matches = self.weekday match {
        Some(w) => d.weekday() as i32 == w
        None => true
    }
    if !doy_matches or !weekday_matches {
        return Err(TimeError.InvalidDate)
    }
    return Ok(d)
}

fn calendar_date(self: Fields, year: i32) Result(Date, TimeError) {
    const has_month_day = self.month.is_some() and self.day.is_some()
    if has_month_day {
        return date(year, self.month.unwrap() as Month, self.day.unwrap())
    }
    const n = self.day_of_year match {
        Some(n) => n
        None => return Err(TimeError.BadFormat)
    }
    const jan1 = date(year, Month.January, 1)?
    if n < 1 or n > days_in_year(year) {
        return Err(TimeError.InvalidDate)
    }
    return Ok(date_from_epoch_day(jan1.epoch_day as i64 + n as i64 - 1))
}

pub fn to_time(self: Fields) Result(Time, TimeError) {
    const hour = self.hour12 match {
        Some(h) => clock_hour(h, self.pm)?
        None => self.hour.unwrap_or(0)
    }
    const second = if self.second == 60 { 59 } else { self.second }
    const t = time(hour, self.minute, second)?
    return Ok(t + ticks(self.frac))
}

fn clock_hour(h12: i32, pm: bool) Result(i32, TimeError) {
    if h12 < 1 or h12 > 12 {
        return Err(TimeError.InvalidTime)
    }
    return Ok(h12 % 12 + (if pm { 12 } else { 0 }))
}

pub fn to_datetime(self: Fields) Result(DateTime, TimeError) {
    return Ok(datetime(self.to_date()?, self.to_time()?))
}
