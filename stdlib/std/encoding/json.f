// JSON encoding, decoding, and DOM manipulation.
//
//   JsonEncoder  — implements Encoder for JSON output to a Writer
//   JsonDecoder  — implements Decoder for JSON input from a Reader;
//                  also handles DOM parsing (parse_value)
//   JsonValue    — recursive tagged union with custom serialize/deserialize
//   parse()      — DOM-level parse from Reader or String
//   stringify()  — DOM-level serialize via JsonEncoder

import std.encoding.codec
import std.io.reader
import std.io.writer
import std.allocator
import std.conv
import std.dict
import std.enum
import std.interface
import std.list
import std.result
import std.string
import std.string_builder
import std.string_reader
import std.test

// =============================================================================
// Errors
// =============================================================================

pub type JsonError = enum {
    UnexpectedChar
    UnexpectedEnd
    InvalidNumber
    InvalidEscape
    InvalidUnicode
    MaxDepthExceeded
    TrailingContent
}

#enum_utils(JsonError)

// =============================================================================
// DOM Types
// =============================================================================

pub type JsonValue = enum {
    Null
    Bool(bool)
    Number(f64)
    Str(OwnedString)
    Array(List(JsonValue))
    Object(Dict(OwnedString, JsonValue))
}

// =============================================================================
// DOM Constructors
// =============================================================================

pub fn json_null() JsonValue { return JsonValue.Null }
pub fn json_bool(value: bool) JsonValue { return JsonValue.Bool(value) }
pub fn json_number(value: f64) JsonValue { return JsonValue.Number(value) }

pub fn json_string(value: String, allocator: &Allocator? = null) JsonValue {
    return JsonValue.Str(from_view(value, allocator))
}

pub fn json_array(allocator: &Allocator? = null) JsonValue {
    let items: List(JsonValue) = list(0, allocator)
    return JsonValue.Array(items)
}

pub fn json_object(allocator: &Allocator? = null) JsonValue {
    let d: Dict(OwnedString, JsonValue)
    d.allocator = allocator
    return JsonValue.Object(d)
}

// =============================================================================
// DOM Predicates
// =============================================================================

pub fn is_null(self: &JsonValue) bool {
    return self.* match { Null => true, else => false }
}

pub fn is_bool(self: &JsonValue) bool {
    return self.* match { Bool(_) => true, else => false }
}

pub fn is_number(self: &JsonValue) bool {
    return self.* match { Number(_) => true, else => false }
}

pub fn is_string(self: &JsonValue) bool {
    return self.* match { Str(_) => true, else => false }
}

pub fn is_array(self: &JsonValue) bool {
    return self.* match { Array(_) => true, else => false }
}

pub fn is_object(self: &JsonValue) bool {
    return self.* match { Object(_) => true, else => false }
}

// =============================================================================
// DOM Accessors
// =============================================================================

pub fn as_bool(self: &JsonValue) bool? {
    return self.* match { Bool(v) => v, else => null }
}

pub fn as_number(self: &JsonValue) f64? {
    return self.* match { Number(v) => v, else => null }
}

pub fn as_string(self: &JsonValue) String? {
    return self.* match { Str(s) => s.as_view(), else => null }
}

pub fn as_array(self: &JsonValue) &List(JsonValue)? {
    return self.* match { Array(arr) => &arr, else => null }
}

pub fn as_object(self: &JsonValue) &Dict(OwnedString, JsonValue)? {
    return self.* match { Object(obj) => &obj, else => null }
}

// =============================================================================
// JSON Object convenience — String-key access for Dict(OwnedString, JsonValue)
// =============================================================================

pub fn json_get(self: &Dict(OwnedString, JsonValue), key: String) JsonValue? {
    return self.get(key)
}

pub fn json_set(self: &Dict(OwnedString, JsonValue), key: String, value: JsonValue) {
    self.set(key, value)
}

pub fn json_contains(self: &Dict(OwnedString, JsonValue), key: String) bool {
    return self.contains(key)
}

// =============================================================================
// Cleanup
// =============================================================================

pub fn deinit(self: &JsonValue) {
    self.* match {
        Str(s) => s.deinit(),
        Array(arr) => {
            for i in 0..arr.len {
                let item = arr[i]
                item.deinit()
            }
            arr.deinit()
        },
        Object(obj) => {
            let it = obj.iter()
            loop {
                let entry = it.next()
                if entry.is_none() { break }
                entry.value.key.deinit()
                entry.value.value.deinit()
            }
            obj.deinit()
        },
        else => {},
    }
}

// =============================================================================
// Writer helpers
// =============================================================================

fn write_str(w: Writer, s: String) {
    w.write(slice_from_raw_parts(s.ptr, s.len))
}

fn write_byte(w: Writer, b: u8) {
    let byte = b
    w.write(slice_from_raw_parts(&byte, 1))
}

fn write_f64(w: Writer, v: f64) {
    let tmp = string_builder(32)
    tmp.append(v)
    w.write(slice_from_raw_parts(tmp.ptr, tmp.len))
    tmp.deinit()
}

fn write_escaped_string(s: String, w: Writer) {
    for i in 0..s.len {
        const c = s[i]
        if c == '"' { write_str(w, "\\\"") }
        else if c == '\\' { write_str(w, "\\\\") }
        else if c == '\n' { write_str(w, "\\n") }
        else if c == '\r' { write_str(w, "\\r") }
        else if c == '\t' { write_str(w, "\\t") }
        else if c < 0x20 {
            write_str(w, "\\u00")
            let hi = (c >> 4) & 0x0F
            let lo = c & 0x0F
            write_byte(w, if hi < 10 { '0' + hi } else { 'a' + hi - 10 })
            write_byte(w, if lo < 10 { '0' + lo } else { 'a' + lo - 10 })
        }
        else { write_byte(w, c) }
    }
}

// =============================================================================
// DOM Parsing
// =============================================================================

// Parse a complete JSON document from a Reader.
pub fn parse(r: Reader, allocator: &Allocator? = null) Result(JsonValue, JsonError) {
    let p = json_decoder(r, allocator)
    let result = p.parse_value()
    if result.is_err() { return result }
    p.skip_whitespace()
    if p.peek().is_some() {
        return Result.Err(JsonError.TrailingContent)
    }
    return result
}

// Parse a complete JSON document from a string.
pub fn parse(input: String, allocator: &Allocator? = null) Result(JsonValue, JsonError) {
    return parse(input.reader(), allocator)
}

// =============================================================================
// DOM Serialization
// =============================================================================

// Custom serialize for JsonValue — walks the DOM tree via the Encoder interface.
// This is the single implementation; stringify/stringify_pretty are thin wrappers.
pub fn serialize(self: &JsonValue, enc: &Encoder) {
    self.* match {
        Null => { enc.encode_null() },
        Bool(b) => { enc.encode_bool(b) },
        Number(n) => { enc.encode_float(n, 8) },
        Str(s) => { enc.encode_str(s.as_view()) },
        Array(arr) => {
            enc.begin_seq(arr.len)
            for i in 0..arr.len as isize {
                let item = &arr.get(i as usize)
                item.serialize(enc)
            }
            enc.end_seq()
        },
        Object(obj) => {
            enc.begin_map(obj.len())
            let it = obj.iter()
            loop {
                let entry = it.next()
                if entry.is_none() { break }
                enc.key(entry.value.key.as_view())
                let v = &entry.value.value
                v.serialize(enc)
            }
            enc.end_map()
        },
    }
}

pub fn stringify(value: &JsonValue, w: Writer) {
    let enc = json_encoder(w)
    value.serialize(&enc.encoder())
}

pub fn stringify(value: &JsonValue) OwnedString {
    let sb = string_builder(64)
    defer sb.deinit()
    let enc = json_encoder(sb.writer())
    value.serialize(&enc.encoder())
    let result = sb.to_string()
    return result
}

pub fn stringify_pretty(value: &JsonValue, w: Writer, indent: usize = 2) {
    let enc = json_encoder(w, true, indent)
    value.serialize(&enc.encoder())
}

// Format protocol — compact by default, "p" for pretty.
pub fn format(self: JsonValue, sb: &StringBuilder, spec: String) {
    let w = sb.writer()
    if spec == "p" { stringify_pretty(&self, w) }
    else { stringify(&self, w) }
}

// =============================================================================
// JsonEncoder — implements Encoder for JSON output to a Writer
// =============================================================================

pub type JsonEncoder = struct {
    w: Writer
    stack: [u8; 64]     // 0 = no elements yet, 1 = has elements
    stack_len: usize
    pretty: bool
    indent: usize
}

pub fn json_encoder(w: Writer, pretty: bool = false, indent: usize = 2) JsonEncoder {
    return .{ w = w, pretty = pretty, indent = indent }
}

fn write_separator(self: &JsonEncoder) {
    if self.stack_len > 0 {
        if self.stack[self.stack_len - 1] == 1 {
            write_byte(self.w, ',')
            if self.pretty {
                write_byte(self.w, '\n')
                self.write_depth()
            }
        } else {
            self.stack[self.stack_len - 1] = 1
            if self.pretty {
                write_byte(self.w, '\n')
                self.write_depth()
            }
        }
    }
}

fn write_depth(self: &JsonEncoder) {
    const total = self.stack_len * self.indent
    for i in 0..total as isize { write_byte(self.w, ' ') }
}

pub fn encode_null(self: &JsonEncoder) usize {
    self.write_separator()
    write_str(self.w, "null")
    return 4
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

pub fn encode_float(self: &JsonEncoder, v: f64, width: u8) usize {
    self.write_separator()
    write_f64(self.w, v)
    return 0
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
        if i > 0 { write_byte(self.w, ',') }
        let buf = [0u8; 3]
        const len = format_u64(v[i] as u64, buf).unwrap()
        self.w.write(slice_from_raw_parts(&buf[0], len))
    }
    write_byte(self.w, ']')
    return 0
}

pub fn begin_seq(self: &JsonEncoder, len: usize) usize {
    self.write_separator()
    write_byte(self.w, '[')
    self.stack[self.stack_len] = 0
    self.stack_len = self.stack_len + 1
    return 1
}

pub fn end_seq(self: &JsonEncoder) usize {
    self.stack_len = self.stack_len - 1
    if self.pretty {
        if self.stack[self.stack_len] == 1 {
            write_byte(self.w, '\n')
            self.write_depth()
        }
    }
    write_byte(self.w, ']')
    return 1
}

pub fn begin_map(self: &JsonEncoder, len: usize) usize {
    self.write_separator()
    write_byte(self.w, '{')
    self.stack[self.stack_len] = 0
    self.stack_len = self.stack_len + 1
    return 1
}

pub fn end_map(self: &JsonEncoder) usize {
    self.stack_len = self.stack_len - 1
    if self.pretty {
        if self.stack[self.stack_len] == 1 {
            write_byte(self.w, '\n')
            self.write_depth()
        }
    }
    write_byte(self.w, '}')
    return 1
}

pub fn key(self: &JsonEncoder, name: String) usize {
    self.write_separator()
    write_byte(self.w, '"')
    write_escaped_string(name, self.w)
    write_byte(self.w, '"')
    write_byte(self.w, ':')
    if self.pretty { write_byte(self.w, ' ') }
    // Mark that the value following this key should NOT get a separator
    self.stack[self.stack_len - 1] = 0
    return name.len + 3
}

pub fn is_human_readable(self: &JsonEncoder) bool { return true }

#implement(JsonEncoder, Encoder)

// =============================================================================
// JsonDecoder — implements Decoder for JSON input from a Reader
// =============================================================================

// Unified JSON decoder: handles both DOM parsing (parse_value) and streaming
// deserialization (Decoder interface). Reads from a Reader with an internal
// 256-byte buffer and single-byte lookahead.
pub type JsonDecoder = struct {
    reader: Reader
    buf: [u8; 256]
    buf_pos: usize
    buf_end: usize
    peeked: u8?
    pos: usize
    allocator: &Allocator?
    error: JsonError?
    // Comma state per nesting level: 0 = expect first, 1 = expect comma
    stack: [u8; 64]
    stack_len: usize
}

pub fn json_decoder(r: Reader, allocator: &Allocator? = null) JsonDecoder {
    return .{ reader = r, allocator = allocator }
}

pub fn get_error(self: &JsonDecoder) JsonError? { return self.error }

fn set_error(self: &JsonDecoder, err: JsonError) {
    if self.error.is_none() { self.error = err }
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
    return b
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
    return c.value == expected
}

fn expect_string(self: &JsonDecoder, expected: String) bool {
    for i in 0..expected.len {
        let c = self.advance()
        if c.is_none() { return false }
        if c.value != expected[i] { return false }
    }
    return true
}

fn skip_whitespace(self: &JsonDecoder) {
    loop {
        let c = self.peek()
        if c.is_none() { return }
        if c.value != ' ' and c.value != '\t' and c.value != '\n' and c.value != '\r' {
            return
        }
        self.advance()
    }
}

// ---- DOM parsing ----

fn parse_value(self: &JsonDecoder) Result(JsonValue, JsonError) {
    self.skip_whitespace()
    let c = self.peek()
    if c.is_none() { return Result.Err(JsonError.UnexpectedEnd) }

    if c.value == '"' { return self.scan_string_value() }
    if c.value == '{' { return self.scan_object() }
    if c.value == '[' { return self.scan_array() }
    if c.value == 't' { return self.scan_true() }
    if c.value == 'f' { return self.scan_false() }
    if c.value == 'n' { return self.scan_null() }
    if c.value == '-' { return self.scan_number() }
    if c.value >= '0' and c.value <= '9' { return self.scan_number() }

    return Result.Err(JsonError.UnexpectedChar)
}

fn scan_null(self: &JsonDecoder) Result(JsonValue, JsonError) {
    if self.expect_string("null") == false { return Result.Err(JsonError.UnexpectedChar) }
    return Result.Ok(JsonValue.Null)
}

fn scan_true(self: &JsonDecoder) Result(JsonValue, JsonError) {
    if self.expect_string("true") == false { return Result.Err(JsonError.UnexpectedChar) }
    return Result.Ok(JsonValue.Bool(true))
}

fn scan_false(self: &JsonDecoder) Result(JsonValue, JsonError) {
    if self.expect_string("false") == false { return Result.Err(JsonError.UnexpectedChar) }
    return Result.Ok(JsonValue.Bool(false))
}

fn scan_string_value(self: &JsonDecoder) Result(JsonValue, JsonError) {
    let sb = string_builder(32, self.allocator)
    if self.scan_string_into(sb.writer()) == false {
        sb.deinit()
        return Result.Err(JsonError.UnexpectedEnd)
    }
    let result = sb.to_string()
    sb.deinit()
    return Result.Ok(JsonValue.Str(result))
}

// Parse a JSON string, writing unescaped content to w.
// Returns false on error.
fn scan_string_into(self: &JsonDecoder, w: Writer) bool {
    if self.expect_char('"') == false { return false }

    loop {
        let c = self.advance()
        if c.is_none() { return false }
        if c.value == '"' { return true }
        if c.value == '\\' {
            let escaped = self.advance()
            if escaped.is_none() { return false }
            if escaped.value == '"' { write_byte(w, '"') }
            else if escaped.value == '\\' { write_byte(w, '\\') }
            else if escaped.value == '/' { write_byte(w, '/') }
            else if escaped.value == 'n' { write_byte(w, '\n') }
            else if escaped.value == 'r' { write_byte(w, '\r') }
            else if escaped.value == 't' { write_byte(w, '\t') }
            else if escaped.value == 'b' { write_byte(w, 8 as u8) }
            else if escaped.value == 'f' { write_byte(w, 12 as u8) }
            else if escaped.value == 'u' {
                // TODO: \uXXXX unicode escapes
                return false
            }
            else { return false }
        } else {
            write_byte(w, c.value)
        }
    }
    return false
}

// Scan a JSON number, copying digit bytes into buf.
// Returns the number of bytes written.
fn scan_number_into(self: &JsonDecoder, buf: u8[]) usize {
    let len: usize = 0

    // Optional minus
    let c = self.peek()
    if c.is_some() {
        if c.value == '-' {
            buf[len] = c.value
            len = len + 1
            self.advance()
        }
    }

    // Integer digits
    for i in 0..64u8 {
        c = self.peek()
        if c.is_none() { break }
        if c.value < '0' { break }
        if c.value > '9' { break }
        buf[len] = c.value
        len = len + 1
        self.advance()
    }

    // Fractional part
    c = self.peek()
    if c.is_some() {
        if c.value == '.' {
            buf[len] = c.value
            len = len + 1
            self.advance()
            for i in 0..64u8 {
                c = self.peek()
                if c.is_none() { break }
                if c.value < '0' { break }
                if c.value > '9' { break }
                buf[len] = c.value
                len = len + 1
                self.advance()
            }
        }
    }

    // Exponent part
    c = self.peek()
    if c.is_some() {
        if c.value == 'e' or c.value == 'E' {
            buf[len] = c.value
            len = len + 1
            self.advance()
            c = self.peek()
            if c.is_some() {
                if c.value == '+' or c.value == '-' {
                    buf[len] = c.value
                    len = len + 1
                    self.advance()
                }
            }
            for i in 0..64u8 {
                c = self.peek()
                if c.is_none() { break }
                if c.value < '0' { break }
                if c.value > '9' { break }
                buf[len] = c.value
                len = len + 1
                self.advance()
            }
        }
    }

    return len
}

fn scan_number(self: &JsonDecoder) Result(JsonValue, JsonError) {
    let num_buf = [0u8; 32]
    let num_len = self.scan_number_into(slice_from_raw_parts(&num_buf[0], 32))
    if num_len == 0 {
        return Result.Err(JsonError.InvalidNumber)
    }
    // TODO: proper string-to-f64 conversion
    let value: f64 = 0.0
    return Result.Ok(JsonValue.Number(value))
}

fn scan_array(self: &JsonDecoder) Result(JsonValue, JsonError) {
    self.expect_char('[')
    self.skip_whitespace()

    let items: List(JsonValue) = list(0, self.allocator)

    let c = self.peek()
    if c.is_some() {
        if c.value == ']' {
            self.advance()
            return Result.Ok(JsonValue.Array(items))
        }
    }

    loop {
        let elem = self.parse_value()
        if elem.is_err() {
            items.deinit()
            return Result.Err(elem.unwrap_err())
        }
        items.push(elem.unwrap())

        self.skip_whitespace()
        c = self.peek()
        if c.is_none() {
            items.deinit()
            return Result.Err(JsonError.UnexpectedEnd)
        }
        if c.value == ']' {
            self.advance()
            return Result.Ok(JsonValue.Array(items))
        }
        if c.value == ',' {
            self.advance()
            continue
         }

        items.deinit()
        return Result.Err(JsonError.UnexpectedChar)
    }

    items.deinit()
    return Result.Err(JsonError.UnexpectedEnd)
}

fn scan_object(self: &JsonDecoder) Result(JsonValue, JsonError) {
    self.expect_char('{')
    self.skip_whitespace()

    let obj: Dict(OwnedString, JsonValue)
    obj.allocator = self.allocator

    let c = self.peek()
    if c.is_some() {
        if c.value == '}' {
            self.advance()
            return Result.Ok(JsonValue.Object(obj))
        }
    }

    loop {
        self.skip_whitespace()

        // Key
        let key_sb = string_builder(32, self.allocator)
        if self.scan_string_into(key_sb.writer()) == false {
            key_sb.deinit()
            obj.deinit()
            return Result.Err(JsonError.UnexpectedEnd)
        }

        self.skip_whitespace()
        if self.expect_char(':') == false {
            key_sb.deinit()
            obj.deinit()
            return Result.Err(JsonError.UnexpectedChar)
        }

        // Value
        let val_result = self.parse_value()
        if val_result.is_err() {
            key_sb.deinit()
            obj.deinit()
            return Result.Err(val_result.unwrap_err())
        }

        let key = key_sb.to_string()
        key_sb.deinit()
        obj.set(key, val_result.unwrap())

        self.skip_whitespace()
        c = self.peek()
        if c.is_none() {
            obj.deinit()
            return Result.Err(JsonError.UnexpectedEnd)
        }
        if c.value == '}' {
            self.advance()
            return Result.Ok(JsonValue.Object(obj))
        }
        if c.value == ',' {
            self.advance()
            continue
        }

        obj.deinit()
        return Result.Err(JsonError.UnexpectedChar)
    }

    obj.deinit()
    return Result.Err(JsonError.UnexpectedEnd)
}

// ---- Decoder interface ----

fn consume_separator(self: &JsonDecoder) {
    if self.stack_len > 0 {
        if self.stack[self.stack_len - 1] == 1 {
            self.skip_whitespace()
            self.expect_char(',')
        } else {
            self.stack[self.stack_len - 1] = 1
        }
    }
}

pub fn decode_null(self: &JsonDecoder) bool {
    if self.error.is_some() { return false }
    self.consume_separator()
    self.skip_whitespace()
    let c = self.peek()
    if c.is_some() {
        if c.value == 'n' {
            if self.expect_string("null") { return true }
            self.set_error(JsonError.UnexpectedChar)
            return false
        }
    }
    return false
}

pub fn decode_bool(self: &JsonDecoder) bool {
    if self.error.is_some() { return false }
    self.consume_separator()
    self.skip_whitespace()
    let c = self.peek()
    if c.is_none() {
        self.set_error(JsonError.UnexpectedEnd)
        return false
    }
    if c.value == 't' {
        if self.expect_string("true") { return true }
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    if c.value == 'f' {
        if self.expect_string("false") { return false }
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    self.set_error(JsonError.UnexpectedChar)
    return false
}

pub fn decode_int(self: &JsonDecoder, width: u8) i64 {
    if self.error.is_some() { return 0 }
    self.consume_separator()
    self.skip_whitespace()
    let num_buf = [0u8; 32]
    let num_len = self.scan_number_into(slice_from_raw_parts(&num_buf[0], 32))
    if num_len == 0 {
        self.set_error(JsonError.InvalidNumber)
        return 0
    }
    const s = slice_from_raw_parts(&num_buf[0], num_len) as String
    const result = parse_i64(s)
    if result.is_err() {
        self.set_error(JsonError.InvalidNumber)
        return 0
    }
    return result.unwrap().0
}

pub fn decode_uint(self: &JsonDecoder, width: u8) u64 {
    if self.error.is_some() { return 0 }
    self.consume_separator()
    self.skip_whitespace()
    let num_buf = [0u8; 32]
    let num_len = self.scan_number_into(slice_from_raw_parts(&num_buf[0], 32))
    if num_len == 0 {
        self.set_error(JsonError.InvalidNumber)
        return 0
    }
    const s = slice_from_raw_parts(&num_buf[0], num_len) as String
    const result = parse_u64(s)
    if result.is_err() {
        self.set_error(JsonError.InvalidNumber)
        return 0
    }
    return result.unwrap().0
}

pub fn decode_float(self: &JsonDecoder, width: u8) f64 {
    if self.error.is_some() { return 0.0 }
    self.consume_separator()
    self.skip_whitespace()
    // TODO: proper string-to-f64 conversion
    let num_buf = [0u8; 32]
    let num_len = self.scan_number_into(slice_from_raw_parts(&num_buf[0], 32))
    if num_len == 0 {
        self.set_error(JsonError.InvalidNumber)
        return 0.0
    }
    let value: f64 = 0.0
    return value
}

pub fn decode_str(self: &JsonDecoder, w: Writer) bool {
    if self.error.is_some() { return false }
    self.consume_separator()
    self.skip_whitespace()
    if self.scan_string_into(w) == false {
        self.set_error(JsonError.UnexpectedEnd)
        return false
    }
    return true
}

pub fn decode_bytes(self: &JsonDecoder, w: Writer) bool {
    // JSON has no native bytes type. Decode an array of numbers.
    if self.error.is_some() { return false }
    self.consume_separator()
    self.skip_whitespace()
    if self.expect_char('[') == false {
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    self.skip_whitespace()
    let c = self.peek()
    if c.is_some() {
        if c.value == ']' {
            self.advance()
            return true
        }
    }
    loop {
        self.skip_whitespace()
        let num_buf = [0u8; 32]
        let num_len = self.scan_number_into(slice_from_raw_parts(&num_buf[0], 32))
        if num_len == 0 {
            self.set_error(JsonError.InvalidNumber)
            return false
        }
        const s = slice_from_raw_parts(&num_buf[0], num_len) as String
        const result = parse_u64(s)
        if result.is_err() {
            self.set_error(JsonError.InvalidNumber)
            return false
        }
        let byte = result.unwrap().0 as u8
        w.write(slice_from_raw_parts(&byte, 1))
        self.skip_whitespace()
        c = self.peek()
        if c.is_none() {
            self.set_error(JsonError.UnexpectedEnd)
            return false
        }
        if c.value == ']' {
            self.advance()
            return true
        }
        if c.value == ',' {
            self.advance()
            continue
        }
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    self.set_error(JsonError.UnexpectedEnd)
    return false
}

pub fn begin_seq(self: &JsonDecoder) usize {
    if self.error.is_some() { return 0 }
    self.consume_separator()
    self.skip_whitespace()
    if self.expect_char('[') == false {
        self.set_error(JsonError.UnexpectedChar)
        return 0
    }
    self.stack[self.stack_len] = 0
    self.stack_len = self.stack_len + 1
    return 0
}

pub fn end_seq(self: &JsonDecoder) bool {
    if self.error.is_some() { return false }
    self.skip_whitespace()
    if self.expect_char(']') == false {
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    self.stack_len = self.stack_len - 1
    return true
}

pub fn begin_map(self: &JsonDecoder) usize {
    if self.error.is_some() { return 0 }
    self.consume_separator()
    self.skip_whitespace()
    if self.expect_char('{') == false {
        self.set_error(JsonError.UnexpectedChar)
        return 0
    }
    self.stack[self.stack_len] = 0
    self.stack_len = self.stack_len + 1
    return 0
}

pub fn end_map(self: &JsonDecoder) bool {
    if self.error.is_some() { return false }
    self.skip_whitespace()
    if self.expect_char('}') == false {
        self.set_error(JsonError.UnexpectedChar)
        return false
    }
    self.stack_len = self.stack_len - 1
    return true
}

// Read the next key in an object. Appends key text to sb.
// Returns false when '}' is reached (no more keys).
pub fn next_key(self: &JsonDecoder, sb: &StringBuilder) bool {
    if self.error.is_some() { return false }
    self.skip_whitespace()

    let c = self.peek()
    if c.is_none() {
        self.set_error(JsonError.UnexpectedEnd)
        return false
    }
    if c.value == '}' { return false }

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

    // Parse key string
    if self.scan_string_into(sb.writer()) == false {
        self.set_error(JsonError.UnexpectedEnd)
        return false
    }

    // Expect colon
    self.skip_whitespace()
    if self.expect_char(':') == false {
        self.set_error(JsonError.UnexpectedChar)
        return false
    }

    return true
}

// Skip a JSON value without materializing it.
pub fn skip_value(self: &JsonDecoder) bool {
    if self.error.is_some() { return false }
    self.skip_whitespace()
    let c = self.peek()
    if c.is_none() {
        self.set_error(JsonError.UnexpectedEnd)
        return false
    }

    if c.value == '"' {
        self.advance()
        loop {
            let ch = self.advance()
            if ch.is_none() {
                self.set_error(JsonError.UnexpectedEnd)
                return false
            }
            if ch.value == '"' { return true }
            if ch.value == '\\' {
                let esc = self.advance()
                if esc.is_none() {
                    self.set_error(JsonError.UnexpectedEnd)
                    return false
                }
            }
        }
        return false
    }
    if c.value == '{' {
        self.advance()
        self.skip_whitespace()
        c = self.peek()
        if c.is_some() {
            if c.value == '}' {
                self.advance()
                return true
            }
        }
        loop {
            self.skip_whitespace()
            if self.skip_value() == false { return false }
            self.skip_whitespace()
            if self.expect_char(':') == false {
                self.set_error(JsonError.UnexpectedChar)
                return false
            }
            if self.skip_value() == false { return false }
            self.skip_whitespace()
            c = self.peek()
            if c.is_none() {
                self.set_error(JsonError.UnexpectedEnd)
                return false
            }
            if c.value == '}' {
                self.advance()
                return true
            }
            if c.value == ',' {
                self.advance()
                continue
            }
            self.set_error(JsonError.UnexpectedChar)
            return false
        }
        return false
    }
    if c.value == '[' {
        self.advance()
        self.skip_whitespace()
        c = self.peek()
        if c.is_some() {
            if c.value == ']' {
                self.advance()
                return true
            }
        }
        loop {
            if self.skip_value() == false { return false }
            self.skip_whitespace()
            c = self.peek()
            if c.is_none() {
                self.set_error(JsonError.UnexpectedEnd)
                return false
            }
            if c.value == ']' {
                self.advance()
                return true
            }
            if c.value == ',' {
                self.advance()
                continue
            }
            self.set_error(JsonError.UnexpectedChar)
            return false
        }
        return false
    }
    if c.value == 't' { return self.expect_string("true") }
    if c.value == 'f' { return self.expect_string("false") }
    if c.value == 'n' { return self.expect_string("null") }
    // Number
    let num_buf = [0u8; 32]
    let num_len = self.scan_number_into(slice_from_raw_parts(&num_buf[0], 32))
    if num_len == 0 {
        self.set_error(JsonError.InvalidNumber)
        return false
    }
    return true
}

pub fn has_error(self: &JsonDecoder) bool {
    return self.error.is_some()
}

#implement(JsonDecoder, Decoder)

// =============================================================================
// Tests
// =============================================================================

test "parse null" {
    let result = parse("null")
    assert_true(result.is_ok(), "should parse null")
    let val = result.unwrap()
    assert_true(val.is_null(), "should be null")
}

test "parse true" {
    let result = parse("true")
    assert_true(result.is_ok(), "should parse true")
    let val = result.unwrap()
    assert_true(val.is_bool(), "should be bool")
    assert_eq(val.as_bool().value, true, "should be true")
}

test "parse false" {
    let result = parse("false")
    assert_true(result.is_ok(), "should parse false")
    let val = result.unwrap()
    assert_eq(val.as_bool().value, false, "should be false")
}

test "parse string" {
    let result = parse("\"hello\"")
    assert_true(result.is_ok(), "should parse string")
    let val = result.unwrap()
    assert_true(val.is_string(), "should be string")
    assert_eq(val.as_string().value, "hello", "should be hello")
    val.deinit()
}

test "parse string with escapes" {
    let result = parse("\"hello\\nworld\"")
    assert_true(result.is_ok(), "should parse escaped string")
    let val = result.unwrap()
    assert_eq(val.as_string().value, "hello\nworld", "should have newline")
    val.deinit()
}

test "parse empty array" {
    let result = parse("[]")
    assert_true(result.is_ok(), "should parse empty array")
    let val = result.unwrap()
    assert_true(val.is_array(), "should be array")
    assert_eq(val.as_array().value.len, 0, "should be empty")
    val.deinit()
}

test "parse empty object" {
    let result = parse("{}")
    assert_true(result.is_ok(), "should parse empty object")
    let val = result.unwrap()
    assert_true(val.is_object(), "should be object")
    assert_eq(val.as_object().value.len(), 0, "should be empty")
    val.deinit()
}

test "parse nested object" {
    let result = parse("{\"name\": \"flang\", \"version\": 2}")
    assert_true(result.is_ok(), "should parse object")
    let val = result.unwrap()
    assert_true(val.is_object(), "should be object")
    let obj = val.as_object().value
    assert_eq(obj.len(), 2, "should have 2 entries")
    let name = obj.json_get("name")
    assert_true(name.is_some(), "should have name")
    assert_eq(name.value.as_string().value, "flang", "name should be flang")
    val.deinit()
}

test "stringify compact" {
    let obj = json_object()
    let o = obj.as_object().value
    o.json_set("a", json_number(1.0))
    o.json_set("b", json_bool(true))
    o.json_set("c", json_null())

    let sb = string_builder(64)
    stringify(&obj, sb.writer())
    assert_true(sb.as_view().len > 0, "should produce output")
    sb.deinit()
    obj.deinit()
}

test "trailing content is error" {
    let result = parse("null null")
    assert_true(result.is_err(), "should reject trailing content")
}

test "json_object builder" {
    let val = json_object()
    let obj = val.as_object().value
    obj.json_set("key", json_string("value"))
    assert_true(obj.json_contains("key"), "should contain key")
    assert_eq(obj.json_get("key").value.as_string().value, "value", "should get value")
    val.deinit()
}

test "encoder compact" {
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

test "decoder basic" {
    let mr = mem_reader("{\"x\": 42, \"y\": true}")
    let dec = json_decoder(mr.reader())
    let d = dec.decoder()
    d.begin_map()
    let kb = string_builder(16)

    kb.clear()
    assert_true(d.next_key(&kb), "should have key x")
    assert_eq(kb.as_view(), "x", "key should be x")
    assert_eq(d.decode_int(8), 42, "x should be 42")

    kb.clear()
    assert_true(d.next_key(&kb), "should have key y")
    assert_eq(kb.as_view(), "y", "key should be y")
    assert_eq(d.decode_bool(), true, "y should be true")

    assert_true(d.next_key(&kb) == false, "no more keys")
    d.end_map()
    assert_true(d.has_error() == false, "no errors")
    kb.deinit()
}
