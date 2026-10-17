// JSON encoding and decoding.
//
//   JsonEncoder  - implements Encoder for JSON output to a Writer
//   JsonDecoder  - implements Decoder for JSON input from a Reader
//   parse_json   - a whole document into a std.encoding.value tree
//   to_json      - a tree back to text
//
// Numbers without a fraction or exponent that fit an i64 read as ints, every other number as a
// float. JSON has no dates: the encoder writes them as ISO 8601 / RFC 3339 strings, and the decoder
// reads strings back as dates and times where `JsonOptions.dates` says so. Object keys keep their
// order, and `JsonOptions.keys` respells them both ways. An absent value (`encode_none`) leaves its
// object entry out and is null anywhere else.

import std.allocator
import std.collections.list
import std.collections.ordered_dict
import std.conv
import std.encoding.codec
import std.encoding.utf8
import std.encoding.value
import std.enum
import std.interface
import std.io.reader
import std.io.writer
import std.option
import std.result
import std.string
import std.string_builder
import std.string_reader
import std.test
import std.time

// =============================================================================
// Errors and options
// =============================================================================

pub type JsonError = enum {
    UnexpectedChar
    UnexpectedEnd
    InvalidNumber
    InvalidEscape
    InvalidUnicode
    MaxDepthExceeded
    TrailingContent
    // NaN or an infinity, which JSON cannot write.
    NonFiniteNumber
    // A string read as a date or time that is not one.
    InvalidDate
}

#enum_utils(JsonError)

// Nesting the encoder and decoder track: arrays and objects open at once.
const MAX_DEPTH: usize = 64

pub type JsonOptions = struct {
    // Which strings the decoder reports as dates and times.
    dates: DateParsing
    // How object keys are spelled on the wire: the encoder respells the keys it writes, the decoder
    // the keys it reads.
    keys: KeyCase
}

// Options with every string kept a string and keys verbatim.
pub fn json_options() JsonOptions {
    return .{ dates = DateParsing.Off, keys = KeyCase.Verbatim }
}

pub fn json_options(dates: DateParsing) JsonOptions {
    return .{ dates = dates, keys = KeyCase.Verbatim }
}

pub fn json_options(keys: KeyCase) JsonOptions {
    return .{ dates = DateParsing.Off, keys = keys }
}

// =============================================================================
// Documents
// =============================================================================

// Parse one JSON document from a Reader into a tree.
pub fn parse_json(
    r: Reader,
    options: JsonOptions = json_options(),
    allocator: &Allocator = context.allocator,
) Result(Value, JsonError) {
    let dec = json_decoder(r, options, allocator)
    defer dec.deinit()
    const d = dec.decoder()
    if d.peek_kind() == ValueKind.End {
        return Err(dec.error ?? JsonError.UnexpectedEnd)
    }
    let v = read_value(&d, allocator)
    if dec.error.is_some() {
        v.deinit()
        return Err(dec.error.unwrap())
    }
    dec.skip_whitespace()
    if dec.peek().is_some() {
        v.deinit()
        return Err(JsonError.TrailingContent)
    }
    return Ok(move v)
}

// Parse one JSON document from a string into a tree.
pub fn parse_json(
    input: String,
    options: JsonOptions = json_options(),
    allocator: &Allocator = context.allocator,
) Result(Value, JsonError) {
    let mr = mem_reader(input)
    return parse_json(mr.reader(), options, allocator)
}

// Write a tree as compact JSON, or indented by `indent` spaces when `pretty`.
pub fn to_json(
    value: &Value,
    w: Writer,
    pretty: bool = false,
    indent: usize = 2,
) Result((), JsonError) {
    let enc = json_encoder(w, json_options(), pretty, indent)
    value.serialize(&enc.encoder())
    if enc.error.is_some() {
        return Err(enc.error.unwrap())
    }
    return Ok(())
}

// A tree as compact JSON text.
pub fn to_json(
    value: &Value,
    allocator: &Allocator = context.allocator,
) Result(OwnedString, JsonError) {
    let sb = string_builder(64, allocator)
    defer sb.deinit()
    to_json(value, sb.writer())?
    return Ok(sb.to_string())
}

// =============================================================================
// Text helpers
// =============================================================================

fn write_escaped_string(s: String, w: Writer) {
    for i in 0..s.len {
        const c = s[i]
        c match {
            '"' => write_str(w, "\\\"")
            '\\' => write_str(w, "\\\\")
            '\n' => write_str(w, "\\n")
            '\r' => write_str(w, "\\r")
            '\t' => write_str(w, "\\t")
            0..=0x1F => {
                write_str(w, "\\u00")
                const hi = (c >> 4) & 0x0F
                const lo = c & 0x0F
                write_byte(w, if hi < 10 { '0' + hi } else { 'a' + hi - 10 })
                write_byte(w, if lo < 10 { '0' + lo } else { 'a' + lo - 10 })
            }
            else => write_byte(w, c)
        }
    }
}

// Whether `s` is number text without a fraction or exponent.
fn is_integral(s: String) bool {
    for i in 0..s.len {
        const c = s[i]
        if c == '.' or c == 'e' or c == 'E' {
            return false
        }
    }
    return true
}

// The i64 `s` spells in full, or null.
fn whole_i64(s: String) i64? {
    const r = parse_i64(s.as_raw_bytes())
    if r.is_err() {
        return null
    }
    const pair = r.unwrap()
    if pair.1 != s.len {
        return null
    }
    return Some(pair.0)
}

fn hex_digit(c: u8) u32? {
    return c match {
        '0'..='9' => Some((c - '0') as u32)
        'a'..='f' => Some((c - 'a' + 10) as u32)
        'A'..='F' => Some((c - 'A' + 10) as u32)
        else => null
    }
}

// =============================================================================
// JsonEncoder - implements Encoder for JSON output to a Writer
// =============================================================================

pub type JsonEncoder = struct {
    w: Writer
    // Per open container: 0 = no elements yet, 1 = has elements.
    stack: [u8; 64]
    stack_len: usize
    // The key given and not yet written: it goes out with its value, so an absent value drops it.
    pending: String?
    keys: KeyCase
    pretty: bool
    indent: usize
    error: JsonError?
}

pub fn json_encoder(
    w: Writer,
    options: JsonOptions = json_options(),
    pretty: bool = false,
    indent: usize = 2,
) JsonEncoder {
    return .{
        w = w,
        stack = [0u8; 64],
        stack_len = 0,
        pending = null,
        keys = options.keys,
        pretty = pretty,
        indent = indent,
        error = null,
    }
}

pub fn get_error(self: &JsonEncoder) JsonError? {
    return self.error
}

fn fail(self: &JsonEncoder, err: JsonError) {
    if self.error.is_none() {
        self.error = Some(err)
    }
}

// Everything that precedes a value: the comma after the previous element, the indent, and the
// pending key.
fn write_separator(self: &JsonEncoder) {
    if self.stack_len == 0 {
        return
    }
    const top = self.stack_len - 1
    if self.stack[top] == 1 {
        write_byte(self.w, ',')
    }
    self.stack[top] = 1
    if self.pretty {
        write_byte(self.w, '\n')
        self.write_depth()
    }
    const name = replace(&self.pending, null)
    if name.is_none() {
        return
    }
    write_byte(self.w, '"')
    self.keys match {
        Verbatim => write_escaped_string(name.unwrap(), self.w)
        Camel => write_camel(name.unwrap(), self.w)
    }
    write_byte(self.w, '"')
    write_byte(self.w, ':')
    if self.pretty {
        write_byte(self.w, ' ')
    }
}

// `start_line` as `startLine`: each `_` after the first character dropped and the letter after it
// capitalised. Leading underscores stay.
fn write_camel(name: String, w: Writer) {
    let run: usize = 0
    let upper = false
    for i in 0..name.len {
        const c = name[i]
        const joins = c == '_' and i > 0 and name[i - 1] != '_'
        if joins {
            write_escaped_string(name[run..i], w)
            run = i + 1
            upper = true
            continue
        }
        if upper and c >= 'a' and c <= 'z' {
            write_escaped_string(name[run..i], w)
            write_byte(w, c - 32)
            run = i + 1
        }
        upper = false
    }
    write_escaped_string(name[run..name.len], w)
}

fn write_depth(self: &JsonEncoder) {
    const total = self.stack_len * self.indent
    for i in 0..total as isize { write_byte(self.w, ' ') }
}

fn open(self: &JsonEncoder, bracket: u8) usize {
    self.write_separator()
    if self.stack_len >= MAX_DEPTH {
        self.fail(JsonError.MaxDepthExceeded)
        return 0
    }
    write_byte(self.w, bracket)
    self.stack[self.stack_len] = 0
    self.stack_len = self.stack_len + 1
    return 1
}

fn close(self: &JsonEncoder, bracket: u8) usize {
    if self.stack_len == 0 {
        return 0
    }
    self.stack_len = self.stack_len - 1
    self.pending = null
    if self.pretty {
        if self.stack[self.stack_len] == 1 {
            write_byte(self.w, '\n')
            self.write_depth()
        }
    }
    write_byte(self.w, bracket)
    return 1
}

pub fn encode_null(self: &JsonEncoder) usize {
    self.write_separator()
    write_str(self.w, "null")
    return 4
}

pub fn encode_none(self: &JsonEncoder) usize {
    if self.pending.is_some() {
        self.pending = null
        return 0
    }
    return self.encode_null()
}

pub fn encode_bool(self: &JsonEncoder, v: bool) usize {
    self.write_separator()
    if v {
        write_str(self.w, "true")
        return 4
    }
    else {
        write_str(self.w, "false")
        return 5
    }
}

pub fn encode_int(self: &JsonEncoder, v: i64, width: u8) usize {
    self.write_separator()
    let buf = [0u8; 21]
    const len = format_i64(v, buf).unwrap()
    self.w.write(slice_from_raw_parts(&buf[0], len))
    return len
}

pub fn encode_uint(self: &JsonEncoder, v: u64, width: u8) usize {
    self.write_separator()
    let buf = [0u8; 20]
    const len = format_u64(v, buf).unwrap()
    self.w.write(slice_from_raw_parts(&buf[0], len))
    return len
}

// A float always carries a fraction or exponent, so it reads back as a float.
pub fn encode_float(self: &JsonEncoder, v: f64, width: u8) usize {
    const is_nan = v != v
    const is_inf = v != 0.0 and v * 0.5 == v
    if is_nan or is_inf {
        self.fail(JsonError.NonFiniteNumber)
        return 0
    }
    self.write_separator()
    let buf = [0u8; 32]
    const n = format_f64_shortest(v, buf).unwrap()
    const text = buf[0..n] as String
    self.w.write(buf[0..n])
    if is_integral(text) {
        write_str(self.w, ".0")
    }
    return n
}

pub fn encode_str(self: &JsonEncoder, v: String) usize {
    self.write_separator()
    write_byte(self.w, '"')
    write_escaped_string(v, self.w)
    write_byte(self.w, '"')
    return v.len + 2
}

pub fn encode_bytes(self: &JsonEncoder, v: u8[]) usize {
    // JSON has no native bytes type; encode as array of numbers.
    self.write_separator()
    write_byte(self.w, '[')
    for i in 0..v.len {
        if i > 0 {
            write_byte(self.w, ',')
        }
        let buf = [0u8; 3]
        const len = format_u64(v[i] as u64, buf).unwrap()
        self.w.write(slice_from_raw_parts(&buf[0], len))
    }
    write_byte(self.w, ']')
    return 0
}

pub fn encode_date(self: &JsonEncoder, v: Date) usize {
    self.write_separator()
    write_byte(self.w, '"')
    v.format(self.w, "")
    write_byte(self.w, '"')
    return 0
}

pub fn encode_time(self: &JsonEncoder, v: Time) usize {
    self.write_separator()
    write_byte(self.w, '"')
    v.format(self.w, "")
    write_byte(self.w, '"')
    return 0
}

pub fn encode_datetime(self: &JsonEncoder, v: DateTime) usize {
    self.write_separator()
    write_byte(self.w, '"')
    v.format(self.w, "")
    write_byte(self.w, '"')
    return 0
}

pub fn encode_offset_datetime(self: &JsonEncoder, v: OffsetDateTime) usize {
    self.write_separator()
    write_byte(self.w, '"')
    v.format(self.w, "")
    write_byte(self.w, '"')
    return 0
}

pub fn begin_seq(self: &JsonEncoder, len: usize) usize {
    return self.open('[')
}

pub fn end_seq(self: &JsonEncoder) usize {
    return self.close(']')
}

pub fn begin_map(self: &JsonEncoder, len: usize) usize {
    return self.open('{')
}

pub fn end_map(self: &JsonEncoder) usize {
    return self.close('}')
}

// `name` is written with its value, so it must outlive the call that writes that value.
pub fn key(self: &JsonEncoder, name: String) usize {
    self.pending = Some(name)
    return name.len + 3
}

pub fn is_human_readable(self: &JsonEncoder) bool { return true }

pub fn has_error(self: &JsonEncoder) bool {
    return self.error.is_some()
}

#implement(JsonEncoder, Encoder)

// =============================================================================
// JsonDecoder - implements Decoder for JSON input from a Reader
// =============================================================================

// Streaming JSON decoder over a Reader, with an internal 256-byte buffer and single-byte lookahead.
// `peek_kind` scans a number, and a string when dates are parsed, ahead of the decode that takes
// it. Call `deinit` when done.
pub type JsonDecoder = struct {
    reader: Reader
    buf: [u8; 256]
    buf_pos: usize
    buf_end: usize
    peeked: u8?
    pos: usize
    allocator: &Allocator
    options: JsonOptions
    error: JsonError?
    // Comma state per nesting level: 0 = expect first, 1 = expect comma
    stack: [u8; 64]
    stack_len: usize
    // `peek_kind` already read the comma before the value it looked at.
    sep_done: bool
    // Number text scanned ahead by `peek_kind`; `num_len` 0 when none.
    num: [u8; 32]
    num_len: usize
    // String scanned ahead by `peek_kind`, or the last string a date decode read.
    text: StringBuilder
    has_text: bool
    // The innermost key of each open object, tracked for DateParsing.Keys only.
    keys: List(OwnedString)
}

pub fn json_decoder(
    r: Reader,
    options: JsonOptions = json_options(),
    allocator: &Allocator = context.allocator,
) JsonDecoder {
    return .{
        reader = r,
        buf = [0u8; 256],
        buf_pos = 0,
        buf_end = 0,
        peeked = null,
        pos = 0,
        allocator = allocator,
        options = options,
        error = null,
        stack = [0u8; 64],
        stack_len = 0,
        sep_done = false,
        num = [0u8; 32],
        num_len = 0,
        text = string_builder(0, allocator),
        has_text = false,
        keys = list(0, allocator),
    }
}

pub fn deinit(self: move JsonDecoder) {
    self.text.deinit()
    self.keys.deinit()
}

pub fn get_error(self: &JsonDecoder) JsonError? { return self.error }

fn set_error(self: &JsonDecoder, err: JsonError) {
    if self.error.is_none() {
        self.error = Some(err)
    }
}

// ---- Low-level scanning ----

fn fill_buf(self: &JsonDecoder) {
    let dst = slice_from_raw_parts(&self.buf[0], 256)
    let n = self.reader.read(dst)
    self.buf_pos = 0
    self.buf_end = n
}

fn read_next_byte(self: &JsonDecoder) u8? {
    if self.buf_pos >= self.buf_end {
        self.fill_buf()
        if self.buf_end == 0 {
            return null
        }
    }
    let b = self.buf[self.buf_pos]
    self.buf_pos = self.buf_pos + 1
    return Some(b)
}

fn peek(self: &JsonDecoder) u8? {
    if self.peeked.is_some() {
        return self.peeked
    }
    self.peeked = self.read_next_byte()
    return self.peeked
}

fn advance(self: &JsonDecoder) u8? {
    let c = if self.peeked.is_some() {
        defer self.peeked = null
        self.peeked
    } else {
        self.read_next_byte()
    }
    if c.is_some() {
        self.pos = self.pos + 1
    }
    return c
}

fn expect_char(self: &JsonDecoder, expected: u8) bool {
    let c = self.advance()
    if c.is_none() {
        return false
    }
    return c.unwrap() == expected
}

fn expect_string(self: &JsonDecoder, expected: String) bool {
    for i in 0..expected.len {
        let c = self.advance()
        if c.is_none() {
            return false
        }
        if c.unwrap() != expected[i] {
            return false
        }
    }
    return true
}

fn skip_whitespace(self: &JsonDecoder) {
    let c = self.peek()
    while c.is_some() and (c.unwrap() == ' ' or c.unwrap() == '\t' or c.unwrap() == '\n'
        or c.unwrap() == '\r') {
            self.advance()
            c = self.peek()
        }
}

// Parse a JSON string, writing unescaped content to w. Returns false on error, with the error set.
fn scan_string_into(self: &JsonDecoder, w: Writer) bool {
    if self.expect_char('"') == false {
        self.set_error(JsonError.UnexpectedChar)
        return false
    }

    loop {
        let c = self.advance()
        if c.is_none() {
            self.set_error(JsonError.UnexpectedEnd)
            return false
        }
        if c.unwrap() == '"' {
            return true
        }
        if c.unwrap() != '\\' {
            write_byte(w, c.unwrap())
            continue
        }
        let escaped = self.advance()
        if escaped.is_none() {
            self.set_error(JsonError.UnexpectedEnd)
            return false
        }
        const ok = escaped.unwrap() match {
            '"' => write_unescaped(w, '"')
            '\\' => write_unescaped(w, '\\')
            '/' => write_unescaped(w, '/')
            'n' => write_unescaped(w, '\n')
            'r' => write_unescaped(w, '\r')
            't' => write_unescaped(w, '\t')
            'b' => write_unescaped(w, 8 as u8)
            'f' => write_unescaped(w, 12 as u8)
            'u' => self.scan_unicode_escape(w)
            else => {
                self.set_error(JsonError.InvalidEscape)
                false
            }
        }
        if !ok {
            return false
        }
    }
    return false
}

fn write_unescaped(w: Writer, c: u8) bool {
    write_byte(w, c)
    return true
}

// Four hex digits after `\u`, or null with the error set.
fn scan_hex4(self: &JsonDecoder) u32? {
    let cp: u32 = 0
    for _i in 0..4usize {
        const c = self.advance()
        if c.is_none() {
            self.set_error(JsonError.UnexpectedEnd)
            return null
        }
        const d = hex_digit(c.unwrap())
        if d.is_none() {
            self.set_error(JsonError.InvalidUnicode)
            return null
        }
        cp = cp * 16 + d.unwrap()
    }
    return Some(cp)
}

// The rest of a `\uXXXX` escape, joining a UTF-16 surrogate pair, written as UTF-8.
fn scan_unicode_escape(self: &JsonDecoder, w: Writer) bool {
    const first = self.scan_hex4()
    if first.is_none() {
        return false
    }
    let cp = first.unwrap()
    const is_low = cp >= 0xDC00 and cp <= 0xDFFF
    if is_low {
        self.set_error(JsonError.InvalidUnicode)
        return false
    }
    const is_high = cp >= 0xD800 and cp <= 0xDBFF
    if is_high {
        if !self.expect_char('\\') or !self.expect_char('u') {
            self.set_error(JsonError.InvalidUnicode)
            return false
        }
        const second = self.scan_hex4()
        if second.is_none() {
            return false
        }
        const lo = second.unwrap()
        if lo < 0xDC00 or lo > 0xDFFF {
            self.set_error(JsonError.InvalidUnicode)
            return false
        }
        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
    }
    let utf8 = [0u8; 4]
    const n = encode_char(cp as char, utf8)
    w.write(utf8[0..n])
    return true
}

// Scan a JSON number, copying its bytes into buf. Returns the number of bytes written; 0 with the
// error set when there is no number or it does not fit `buf`.
fn scan_number_into(self: &JsonDecoder, buf: u8[]) usize {
    let len: usize = 0
    let c = self.peek()
    if c.is_some() and c.unwrap() == '-' {
        buf[0] = '-'
        len = 1
        self.advance()
    }
    len = self.scan_digits(buf, len)

    c = self.peek()
    if c.is_some() and c.unwrap() == '.' and len < buf.len {
        buf[len] = '.'
        len = len + 1
        self.advance()
        len = self.scan_digits(buf, len)
    }

    c = self.peek()
    if c.is_some() and (c.unwrap() == 'e' or c.unwrap() == 'E') and len < buf.len {
        buf[len] = c.unwrap()
        len = len + 1
        self.advance()
        c = self.peek()
        if c.is_some() and (c.unwrap() == '+' or c.unwrap() == '-') and len < buf.len {
            buf[len] = c.unwrap()
            len = len + 1
            self.advance()
        }
        len = self.scan_digits(buf, len)
    }

    c = self.peek()
    const too_long = c.is_some() and len == buf.len
    if len == 0 or too_long {
        self.set_error(JsonError.InvalidNumber)
        return 0
    }
    return len
}

// Appends the digits ahead to `buf` from `len`, stopping when it is full. Returns the new length.
fn scan_digits(self: &JsonDecoder, buf: u8[], len: usize) usize {
    let n = len
    while n < buf.len {
        const c = self.peek()
        if c.is_none() {
            break
        }
        if c.unwrap() < '0' or c.unwrap() > '9' {
            break
        }
        buf[n] = c.unwrap()
        n = n + 1
        self.advance()
    }
    return n
}

// The next number's text: the one `peek_kind` scanned ahead, or scanned now. Valid until the next
// number is scanned. Empty on error.
fn number_text(self: &JsonDecoder) String {
    if self.num_len == 0 {
        self.skip_whitespace()
        self.num_len = self.scan_number_into(self.num[0..32])
    }
    const text = self.num[0..self.num_len] as String
    self.num_len = 0
    return text
}

// The next string, unescaped into `self.text`: the one `peek_kind` scanned ahead, or scanned now.
fn read_text(self: &JsonDecoder) bool {
    if self.has_text {
        self.has_text = false
        return true
    }
    self.text.clear()
    self.skip_whitespace()
    return self.scan_string_into(self.text.writer())
}

// ---- Nesting ----

// Reads the comma before an element, unless `peek_kind` already did.
fn consume_separator(self: &JsonDecoder) {
    if self.sep_done {
        self.sep_done = false
        return
    }
    self.separate()
}

fn separate(self: &JsonDecoder) {
    if self.stack_len == 0 {
        return
    }
    if self.stack[self.stack_len - 1] == 0 {
        self.stack[self.stack_len - 1] = 1
        return
    }
    self.skip_whitespace()
    if self.expect_char(',') == false {
        self.set_error(JsonError.UnexpectedChar)
    }
}

fn open(self: &JsonDecoder, bracket: u8) bool {
    if self.error.is_some() {
        return false
    }
    self.consume_separator()
    self.skip_whitespace()
    if self.expect_char(bracket) == false {
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    if self.stack_len >= MAX_DEPTH {
        self.set_error(JsonError.MaxDepthExceeded)
        return false
    }
    self.stack[self.stack_len] = 0
    self.stack_len = self.stack_len + 1
    return true
}

fn close(self: &JsonDecoder, bracket: u8) bool {
    if self.error.is_some() {
        return false
    }
    self.skip_whitespace()
    const c = self.advance()
    if c.is_none() {
        self.set_error(JsonError.UnexpectedEnd)
        return false
    }
    if c.unwrap() != bracket {
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    self.stack_len = self.stack_len - 1
    return true
}

fn tracks_keys(self: &JsonDecoder) bool {
    return self.options.dates match { Keys(_) => true, else => false }
}

// The innermost object key above the next value, when tracked.
fn current_key(self: &JsonDecoder) String? {
    const top = self.keys.last_ref()?
    return Some(top.view)
}

// ---- Decoder interface ----

pub fn peek_kind(self: &JsonDecoder) ValueKind {
    if self.error.is_some() {
        return ValueKind.End
    }
    if self.num_len > 0 {
        return self.number_kind()
    }
    if self.has_text {
        return temporal_kind(self.text.as_view())
    }
    self.skip_whitespace()
    let c = self.peek()
    if c.is_none() {
        return ValueKind.End
    }
    if c.unwrap() == ']' or c.unwrap() == '}' {
        return ValueKind.End
    }
    if !self.sep_done {
        self.separate()
        self.sep_done = true
        self.skip_whitespace()
        c = self.peek()
        if c.is_none() {
            self.set_error(JsonError.UnexpectedEnd)
            return ValueKind.End
        }
    }
    return c.unwrap() match {
        '"' => self.string_kind()
        '{' => ValueKind.Map
        '[' => ValueKind.Seq
        't' | 'f' => ValueKind.Bool
        'n' => ValueKind.Null
        '-' | '0'..='9' => {
            self.num_len = self.scan_number_into(self.num[0..32])
            self.number_kind()
        }
        else => {
            self.set_error(JsonError.UnexpectedChar)
            ValueKind.End
        }
    }
}

fn number_kind(self: &JsonDecoder) ValueKind {
    if self.num_len == 0 {
        return ValueKind.End
    }
    const text = self.num[0..self.num_len] as String
    if is_integral(text) and whole_i64(text).is_some() {
        return ValueKind.Int
    }
    return ValueKind.Float
}

fn string_kind(self: &JsonDecoder) ValueKind {
    if !self.options.dates.applies(self.current_key()) {
        return ValueKind.Str
    }
    self.text.clear()
    if !self.scan_string_into(self.text.writer()) {
        return ValueKind.End
    }
    self.has_text = true
    return temporal_kind(self.text.as_view())
}

pub fn decode_null(self: &JsonDecoder) bool {
    if self.error.is_some() {
        return false
    }
    self.consume_separator()
    self.skip_whitespace()
    let c = self.peek()
    if c.is_some() {
        if c.unwrap() == 'n' {
            if self.expect_string("null") {
                return true
            }
            self.set_error(JsonError.UnexpectedChar)
            return false
        }
    }
    return false
}

pub fn decode_bool(self: &JsonDecoder) bool {
    if self.error.is_some() {
        return false
    }
    self.consume_separator()
    self.skip_whitespace()
    let c = self.peek()
    if c.is_none() {
        self.set_error(JsonError.UnexpectedEnd)
        return false
    }
    if c.unwrap() == 't' {
        if self.expect_string("true") {
            return true
        }
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    if c.unwrap() == 'f' {
        if self.expect_string("false") {
            return false
        }
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    self.set_error(JsonError.UnexpectedChar)
    return false
}

pub fn decode_int(self: &JsonDecoder, width: u8) i64 {
    if self.error.is_some() {
        return 0
    }
    self.consume_separator()
    const n = whole_i64(self.number_text())
    if n.is_none() {
        self.set_error(JsonError.InvalidNumber)
        return 0
    }
    return n.unwrap()
}

pub fn decode_uint(self: &JsonDecoder, width: u8) u64 {
    if self.error.is_some() {
        return 0
    }
    self.consume_separator()
    const s = self.number_text()
    const result = parse_u64(s.as_raw_bytes())
    if result.is_err() or result.unwrap().1 != s.len {
        self.set_error(JsonError.InvalidNumber)
        return 0
    }
    return result.unwrap().0
}

pub fn decode_float(self: &JsonDecoder, width: u8) f64 {
    if self.error.is_some() {
        return 0.0
    }
    self.consume_separator()
    const s = self.number_text()
    const result = parse_f64(s.as_raw_bytes())
    if result.is_err() or result.unwrap().1 != s.len {
        self.set_error(JsonError.InvalidNumber)
        return 0.0
    }
    return result.unwrap().0
}

pub fn decode_str(self: &JsonDecoder, w: Writer) bool {
    if self.error.is_some() {
        return false
    }
    self.consume_separator()
    if self.has_text {
        self.has_text = false
        w.write_str(self.text.as_view())
        return true
    }
    self.skip_whitespace()
    return self.scan_string_into(w)
}

pub fn decode_bytes(self: &JsonDecoder, w: Writer) bool {
    // JSON has no native bytes type. Decode an array of numbers.
    if !self.open('[') {
        return false
    }
    loop {
        self.skip_whitespace()
        let c = self.peek()
        if c.is_none() {
            self.set_error(JsonError.UnexpectedEnd)
            return false
        }
        if c.unwrap() == ']' {
            return self.close(']')
        }
        self.separate()
        self.skip_whitespace()
        const s = self.number_text()
        const result = parse_u64(s.as_raw_bytes())
        if result.is_err() or result.unwrap().1 != s.len or result.unwrap().0 > 255 {
            self.set_error(JsonError.InvalidNumber)
            return false
        }
        let byte = result.unwrap().0 as u8
        w.write(slice_from_raw_parts(&byte, 1))
    }
    return false
}

pub fn decode_date(self: &JsonDecoder) Date {
    const r = if self.date_text() { parse_date(
        self.text.as_view(),
    ) } else { Err(TimeError.BadFormat) }
    if r.is_err() {
        self.set_error(JsonError.InvalidDate)
        return date_from_epoch_day(0)
    }
    return r.unwrap()
}

pub fn decode_time(self: &JsonDecoder) Time {
    const r = if self.date_text() { parse_time(
        self.text.as_view(),
    ) } else { Err(TimeError.BadFormat) }
    if r.is_err() {
        self.set_error(JsonError.InvalidDate)
        return Time { ticks = 0 }
    }
    return r.unwrap()
}

pub fn decode_datetime(self: &JsonDecoder) DateTime {
    const r = if self.date_text() {
        parse_datetime(self.text.as_view())
    } else {
        Err(TimeError.BadFormat)
    }
    if r.is_err() {
        self.set_error(JsonError.InvalidDate)
        return datetime_from_ticks(0)
    }
    return r.unwrap()
}

pub fn decode_offset_datetime(self: &JsonDecoder) OffsetDateTime {
    const r = if self.date_text() {
        parse_offset_datetime(self.text.as_view())
    } else {
        Err(TimeError.BadFormat)
    }
    if r.is_err() {
        self.set_error(JsonError.InvalidDate)
        return OffsetDateTime { instant = UNIX_EPOCH, offset = 0 }
    }
    return r.unwrap()
}

// The string a date decode reads, in `self.text`.
fn date_text(self: &JsonDecoder) bool {
    if self.error.is_some() {
        return false
    }
    self.consume_separator()
    return self.read_text()
}

pub fn begin_seq(self: &JsonDecoder) usize {
    self.open('[')
    return 0
}

pub fn end_seq(self: &JsonDecoder) bool {
    return self.close(']')
}

pub fn begin_map(self: &JsonDecoder) usize {
    if self.open('{') and self.tracks_keys() {
        self.keys.push(from_view("", self.allocator))
    }
    return 0
}

pub fn end_map(self: &JsonDecoder) bool {
    if self.tracks_keys() {
        const k = self.keys.pop()
        if k.is_some() {
            k.unwrap().deinit()
        }
    }
    return self.close('}')
}

// Read the next key in an object. Appends key text to sb. Returns false when '}' is reached (no
// more keys).
pub fn next_key(self: &JsonDecoder, sb: &StringBuilder) bool {
    if self.error.is_some() {
        return false
    }
    self.skip_whitespace()

    let c = self.peek()
    if c.is_none() {
        self.set_error(JsonError.UnexpectedEnd)
        return false
    }
    if c.unwrap() == '}' {
        return false
    }

    // Comma between entries
    if self.stack_len > 0 {
        if self.stack[self.stack_len - 1] == 1 {
            if self.expect_char(',') == false {
                self.set_error(JsonError.UnexpectedChar)
                return false
            }
            self.skip_whitespace()
        } else {
            self.stack[self.stack_len - 1] = 1
        }
    }

    const start = sb.len
    const scanned = self.options.keys match {
        Verbatim => self.scan_string_into(sb.writer())
        Camel => self.scan_snake_key(sb)
    }
    if !scanned {
        return false
    }

    self.skip_whitespace()
    if self.expect_char(':') == false {
        self.set_error(JsonError.UnexpectedChar)
        return false
    }

    // The value after the key takes no comma: next_key reads the commas between entries.
    if self.stack_len > 0 {
        self.stack[self.stack_len - 1] = 0
    }
    if self.tracks_keys() and self.keys.len > 0 {
        const name = sb.as_view()[start..sb.len]
        const old = replace(&self.keys[self.keys.len - 1], from_view(name, self.allocator))
        old.deinit()
    }
    return true
}

// Scan a key and append it to `sb` as snake_case: `startLine` as `start_line`.
fn scan_snake_key(self: &JsonDecoder, sb: &StringBuilder) bool {
    let raw = string_builder(32, self.allocator)
    defer raw.deinit()
    if !self.scan_string_into(raw.writer()) {
        return false
    }
    const text = raw.as_view()
    for i in 0..text.len {
        const c = text[i]
        if c >= 'A' and c <= 'Z' {
            if i > 0 {
                sb.append_byte('_')
            }
            sb.append_byte(c + 32)
            continue
        }
        sb.append_byte(c)
    }
    return true
}

// Skip a JSON value without materializing it.
pub fn skip_value(self: &JsonDecoder) bool {
    if self.error.is_some() {
        return false
    }
    self.consume_separator()
    if self.num_len > 0 {
        self.num_len = 0
        return true
    }
    if self.has_text {
        self.has_text = false
        return true
    }
    return self.skip_raw()
}

// Skips the value ahead, nested values included, leaving the nesting state alone.
fn skip_raw(self: &JsonDecoder) bool {
    self.skip_whitespace()
    const c = self.peek()
    if c.is_none() {
        self.set_error(JsonError.UnexpectedEnd)
        return false
    }
    return c.unwrap() match {
        '"' => self.skip_string()
        '{' => self.skip_container('}', true)
        '[' => self.skip_container(']', false)
        't' => self.expect_string("true")
        'f' => self.expect_string("false")
        'n' => self.expect_string("null")
        else => self.number_text().len > 0
    }
}

fn skip_string(self: &JsonDecoder) bool {
    self.advance()
    loop {
        const ch = self.advance()
        if ch.is_none() {
            self.set_error(JsonError.UnexpectedEnd)
            return false
        }
        if ch.unwrap() == '"' {
            return true
        }
        if ch.unwrap() == '\\' and self.advance().is_none() {
            self.set_error(JsonError.UnexpectedEnd)
            return false
        }
    }
    return false
}

// Skips an array, or an object when `keyed`, up to and including `bracket`.
fn skip_container(self: &JsonDecoder, bracket: u8, keyed: bool) bool {
    self.advance()
    self.skip_whitespace()
    const first = self.peek()
    if first.is_some() and first.unwrap() == bracket {
        self.advance()
        return true
    }
    loop {
        if keyed {
            if !self.skip_raw() {
                return false
            }
            self.skip_whitespace()
            if !self.expect_char(':') {
                self.set_error(JsonError.UnexpectedChar)
                return false
            }
        }
        if !self.skip_raw() {
            return false
        }
        self.skip_whitespace()
        const c = self.advance()
        if c.is_none() {
            self.set_error(JsonError.UnexpectedEnd)
            return false
        }
        if c.unwrap() == bracket {
            return true
        }
        if c.unwrap() != ',' {
            self.set_error(JsonError.UnexpectedChar)
            return false
        }
    }
    return false
}

pub fn has_error(self: &JsonDecoder) bool {
    return self.error.is_some()
}

#implement(JsonDecoder, Decoder)

// =============================================================================
// Tests
// =============================================================================

fn parsed_kind(text: String) ValueKind {
    let v = parse_json(text).unwrap()
    defer v.deinit()
    return v.kind()
}

fn parsed_number(text: String) f64 {
    let v = parse_json(text).unwrap()
    defer v.deinit()
    return v.as_f64().unwrap()
}

fn parse_error(text: String) JsonError {
    const r = parse_json(text)
    return r match {
        Ok(v) => {
            v.deinit()
            panic("parsed")
        }
        Err(e) => e
    }
}

test "scalars parse to their kinds" {
    assert_true(parsed_kind("null") == ValueKind.Null, "null")
    assert_true(parsed_kind("true") == ValueKind.Bool, "true")
    assert_true(parsed_kind("42") == ValueKind.Int, "int")
    assert_eq(parsed_number("-7"), -7.0, "negative int")
    assert_true(parsed_kind("-3.14") == ValueKind.Float, "fraction makes a float")
    const n = parsed_number("-3.14")
    assert_true(n > -3.15 and n < -3.13, "~-3.14")
    assert_true(parsed_kind("1e3") == ValueKind.Float, "exponent makes a float")
    assert_true(parsed_kind("123456789012345678901") == ValueKind.Float, "past i64 is a float")
}

test "strings unescape, \\u escapes included" {
    let v = parse_json("\"a\\nb \\u00e9 \\ud83d\\ude00\"").unwrap()
    defer v.deinit()
    assert_eq(v.as_string().unwrap(), "a\nb \u00e9 \u1F600", "escapes decoded")
    assert_true(parse_error("\"\\ude00\"") == JsonError.InvalidUnicode, "lone low surrogate")
    assert_true(parse_error("\"\\ud83d\"") == JsonError.InvalidUnicode, "lone high surrogate")
    assert_true(parse_error("\"\\q\"") == JsonError.InvalidEscape, "bad escape")
}

test "arrays and objects nest, and object keys keep their order" {
    let v = parse_json(
        "{\"z\": [1, 2.5, \"x\", [], {}], \"a\": {\"k\": null}, \"m\": true}",
    ).unwrap()
    defer v.deinit()
    assert_eq(v.len(), 3 as usize, "three keys")
    const m = v.as_map().unwrap()
    assert_true(m.entry_at(0).unwrap().key.view == "z", "first key")
    assert_true(m.entry_at(1).unwrap().key.view == "a", "second key")
    const z = v.get("z").unwrap()
    assert_eq(z.len(), 5 as usize, "five elements")
    assert_eq(z.at(0).unwrap().as_i64().unwrap(), 1i64, "int element")
    assert_true(z.at(1).unwrap().is_float(), "float element")
    assert_true(z.at(3).unwrap().is_array(), "empty array")
    assert_true(z.at(4).unwrap().is_map(), "empty object")
    assert_true(v.get("a").unwrap().get("k").unwrap().is_null(), "nested null")
}

test "malformed documents are errors" {
    assert_true(parse_error("") == JsonError.UnexpectedEnd, "empty")
    assert_true(parse_error("null null") == JsonError.TrailingContent, "trailing")
    assert_true(parse_error("[1 2]") == JsonError.UnexpectedChar, "missing comma")
    assert_true(parse_error("[1,]") == JsonError.UnexpectedChar, "trailing comma")
    assert_true(parse_error("{\"a\" 1}") == JsonError.UnexpectedChar, "missing colon")
    assert_true(parse_error("[1") == JsonError.UnexpectedEnd, "unclosed")
    let deep = string_builder(256)
    defer deep.deinit()
    for _i in 0..100usize {
        deep.append("[")
    }
    assert_true(parse_error(deep.as_view()) == JsonError.MaxDepthExceeded, "depth")
}

test "to_json writes compact text that parses back" {
    let v = parse_json("{\"b\": [1, 2.0, \"s\\\"q\"], \"a\": {\"x\": null, \"y\": false}}").unwrap()
    defer v.deinit()
    let text = to_json(&v).unwrap()
    defer text.deinit()
    assert_eq(text.view, "{\"b\":[1,2.0,\"s\\\"q\"],\"a\":{\"x\":null,\"y\":false}}", "compact")

    let sb = string_builder(64)
    defer sb.deinit()
    to_json(v.get("a").unwrap(), sb.writer(), true).unwrap()
    assert_eq(sb.as_view(), "{\n  \"x\": null,\n  \"y\": false\n}", "pretty")
}

test "a non-finite float is an encoder error" {
    let sb = string_builder(16)
    defer sb.deinit()
    let zero = 0.0
    const nan = zero / zero
    const v = Value.Float(nan)
    assert_true(to_json(&v, sb.writer()).unwrap_err() == JsonError.NonFiniteNumber, "nan")
}

test "dates are written as ISO 8601 strings and read back where options say" {
    let v = value_map()
    defer v.deinit()
    v.set("day", Value.Date(date(2026, Month.October, 14).unwrap()))
    v.set("at", Value.OffsetDateTime(parse_offset_datetime("2026-10-14T09:30:00+01:00").unwrap()))
    v.set("note", value_str("2026-01-01"))
    let text = to_json(&v).unwrap()
    defer text.deinit()
    assert_eq(
        text.view,
        "{\"day\":\"2026-10-14\",\"at\":\"2026-10-14T09:30:00+01:00\",\"note\":\"2026-01-01\"}",
        "ISO text",
    )

    let off = parse_json(text.view).unwrap()
    defer off.deinit()
    assert_true(off.get("day").unwrap().is_string(), "Off keeps strings")

    let all = parse_json(text.view, json_options(DateParsing.All)).unwrap()
    defer all.deinit()
    assert_true(all.get("day").unwrap().as_date().is_some(), "All reads the date")
    assert_true(all.get("at").unwrap().as_offset_datetime().is_some(), "and the timestamp")
    assert_true(all.get("note").unwrap().as_date().is_some(), "and every other date string")

    const keys = ["day", "at"]
    let some = parse_json(text.view, json_options(DateParsing.Keys(keys[..]))).unwrap()
    defer some.deinit()
    assert_true(some.get("day").unwrap().as_date().is_some(), "listed key read")
    assert_true(some.get("note").unwrap().is_string(), "unlisted key kept")
}

test "encoder writes a stream by hand" {
    let sb = string_builder(64)
    let enc = json_encoder(sb.writer())
    let e = enc.encoder()
    e.begin_map(2)
    e.key("x")
    e.encode_int(42, 8)
    e.key("y")
    e.encode_bool(true)
    e.end_map()
    assert_eq(sb.as_view(), "{\"x\":42,\"y\":true}", "encoder compact")
    sb.deinit()
}

test "decoder reads a stream by hand" {
    let mr = mem_reader("{\"x\": 42, \"skip\": [1, {\"a\": 2}], \"y\": true}")
    let dec = json_decoder(mr.reader())
    defer dec.deinit()
    let d = dec.decoder()
    d.begin_map()
    let kb = string_builder(16)
    defer kb.deinit()

    assert_true(d.next_key(&kb), "should have key x")
    assert_eq(kb.as_view(), "x", "key should be x")
    assert_eq(d.decode_int(8), 42, "x should be 42")

    kb.clear()
    assert_true(d.next_key(&kb), "should have key skip")
    assert_true(d.skip_value(), "skipped")

    kb.clear()
    assert_true(d.next_key(&kb), "should have key y")
    assert_eq(d.decode_bool(), true, "y should be true")

    assert_true(d.next_key(&kb) == false, "no more keys")
    d.end_map()
    assert_true(d.has_error() == false, "no errors")
}

test "transcode streams JSON to JSON" {
    let mr = mem_reader("{\"a\": [1, 2.5, \"x\"], \"b\": {}}")
    let dec = json_decoder(mr.reader())
    defer dec.deinit()
    let sb = string_builder(64)
    defer sb.deinit()
    let enc = json_encoder(sb.writer())
    transcode(&dec.decoder(), &enc.encoder())
    assert_true(!dec.has_error(), "decoded")
    assert_eq(sb.as_view(), "{\"a\":[1,2.5,\"x\"],\"b\":{}}", "same document")
}

test "floats round-trip through JSON text exactly" {
    let v = value_array()
    defer v.deinit()
    v.push(Value.Float(0.1 + 0.2))
    v.push(Value.Float(1.0 / 3.0))
    v.push(Value.Float(1e300))
    v.push(Value.Float(-0.0))
    let text = to_json(&v).unwrap()
    defer text.deinit()
    assert_eq(text.view, "[0.30000000000000004,0.3333333333333333,1e+300,-0.0]", "shortest text")
    let back = parse_json(text.view).unwrap()
    defer back.deinit()
    assert_eq(back.at(0).unwrap().as_f64().unwrap(), 0.1 + 0.2, "0.1 + 0.2 exactly")
    assert_eq(back.at(1).unwrap().as_f64().unwrap(), 1.0 / 3.0, "a third exactly")
}

type KeyProbe = struct {
    start_line: u32
}

#derive(KeyProbe, serialize)

type NoneProbe = struct {
    label: String
    at: KeyProbe
    tags: List(i32)
    note: i32?
}

#derive(NoneProbe, serialize)

test "camel keys respell snake fields, and a None field is left out" {
    let sb = string_builder(64)
    defer sb.deinit()
    let enc = json_encoder(sb.writer(), json_options(KeyCase.Camel))
    let tags: List(i32) = list(2)
    tags.push(1)
    tags.push(2)
    let p = NoneProbe {
        label = "a",
        at = KeyProbe { start_line = 3 },
        tags = move tags,
        note = null,
    }
    p.serialize(&enc.encoder())
    assert_eq(
        sb.as_view(),
        "{\"label\":\"a\",\"at\":{\"startLine\":3},\"tags\":[1,2]}",
        "no note key",
    )

    sb.clear()
    let enc2 = json_encoder(sb.writer(), json_options(KeyCase.Camel))
    p.note = Some(5)
    p.serialize(&enc2.encoder())
    assert_true(contains(sb.as_view(), "[1,2],\"note\":5}"), "Some writes its payload")
    p.tags.deinit()
}

test "a None outside an object is null" {
    let sb = string_builder(16)
    defer sb.deinit()
    let enc = json_encoder(sb.writer())
    let xs: List(i32?) = list(2)
    defer xs.deinit()
    xs.push(null)
    xs.push(Some(1))
    xs.serialize(&enc.encoder())
    assert_eq(sb.as_view(), "[null,1]", "an element cannot be left out")
}

test "camel keys read back as snake fields" {
    let mr = mem_reader("{\"startLine\": 7, \"x\": 1}")
    let dec = json_decoder(mr.reader(), json_options(KeyCase.Camel))
    defer dec.deinit()
    let d = dec.decoder()
    d.begin_map()
    let kb = string_builder(16)
    defer kb.deinit()
    assert_true(d.next_key(&kb), "first key")
    assert_eq(kb.as_view(), "start_line", "startLine reads as start_line")
    assert_eq(d.decode_int(8), 7, "its value")
    kb.clear()
    assert_true(d.next_key(&kb), "second key")
    assert_eq(kb.as_view(), "x", "a key without capitals is unchanged")
}
