// TOML 1.0 documents, read into and written from a std.encoding.value tree.
//
//   parse_toml  - a whole document into a Value map
//   to_toml     - a Value map back to text
//
// TOML maps onto Value one to one: strings, i64 integers, floats, booleans, the four date-time
// kinds (offset date-time, local date-time, local date, local time as OffsetDateTime, DateTime,
// Date, Time), arrays and tables. Tables keep their keys in document order. TOML has no null:
// `to_toml` refuses one. Within a table, `to_toml` writes plain keys before sub-tables, as TOML
// requires.
//
// A TOML document is read whole, because a table may be added to after other tables. For
// `#derive(T, deserialize)`, decode the parsed tree through a `ValueDecoder`.

import std.allocator
import std.collections.dict
import std.collections.list
import std.collections.ordered_dict
import std.conv
import std.encoding.codec
import std.encoding.json
import std.encoding.utf8
import std.encoding.value
import std.enum
import std.io.writer
import std.option
import std.result
import std.string
import std.string_builder
import std.test
import std.time

pub type TomlErrorKind = enum {
    UnexpectedChar
    UnexpectedEnd
    InvalidEscape
    InvalidUnicode
    InvalidNumber
    InvalidDate
    // A key given a value twice.
    DuplicateKey
    // A table defined twice, or extended where TOML forbids it (an inline table, a table given by
    // dotted keys reopened by a header, a header table extended by dotted keys).
    TableRedefined
    // A key path that runs through a value that is not a table.
    NotATable
    // Writing: a null, which TOML cannot hold.
    NullValue
    // Writing: a document whose top level is not a map.
    RootNotTable
}

#enum_utils(TomlErrorKind)

// What went wrong and where. `line` and `column` count from 1; both are 0 for writing errors.
pub type TomlError = struct {
    kind: TomlErrorKind
    line: usize
    column: usize
}

// `DuplicateKey at 3:5`, or the kind alone for a writing error.
pub fn format(self: TomlError, w: Writer, spec: String) {
    w.write_str(self.kind.to_string())
    if self.line == 0 {
        return
    }
    w.write_str(" at ")
    w.write_uint(self.line)
    w.write_byte(':')
    w.write_uint(self.column)
}

// =============================================================================
// Reading
// =============================================================================

// Parse a TOML document into a map.
pub fn parse_toml(input: String, allocator: &Allocator? = null) Result(Value, TomlError) {
    let p = parser(input, allocator)
    defer p.deinit()
    let root = value_map(allocator)
    p.parse_document(&root)
    if p.error.is_some() {
        root.deinit()
        return Err(p.error.unwrap())
    }
    return Ok(move root)
}

// How a table came to exist, kept per table path while a document is read.
const BY_HEADER: u8 = 1
const BY_DOTTED_KEY: u8 = 2
const INLINE: u8 = 4
const ARRAY_OF_TABLES: u8 = 8
const IMPLICIT: u8 = 16

type Parser = struct {
    src: String
    pos: usize
    allocator: &Allocator?
    error: TomlError?
    // The path of the table or value being read, one segment per key or array index (path_key).
    path: StringBuilder
    // Table origins by path.
    origins: Dict(OwnedString, u8)
}

fn parser(src: String, allocator: &Allocator?) Parser {
    return .{
        src = src,
        pos = 0,
        allocator = allocator,
        error = null,
        path = string_builder(64, allocator),
        origins = dict(allocator),
    }
}

fn deinit(self: move Parser) {
    self.path.deinit()
    self.origins.deinit()
}

// ---- Errors and scanning ----

fn fail(self: &Parser, kind: TomlErrorKind) {
    if self.error.is_some() {
        return
    }
    let line: usize = 1
    let line_start: usize = 0
    const end = if self.pos < self.src.len { self.pos } else { self.src.len }
    for i in 0..end {
        if self.src[i] == '\n' {
            line = line + 1
            line_start = i + 1
        }
    }
    self.error = Some(TomlError { kind = kind, line = line, column = end - line_start + 1 })
}

fn failed(self: &Parser) bool {
    return self.error.is_some()
}

fn at_end(self: &Parser) bool {
    return self.pos >= self.src.len
}

// The byte `n` ahead, or 0 past the end.
fn peek_at(self: &Parser, n: usize) u8 {
    const i = self.pos + n
    if i >= self.src.len {
        return 0
    }
    return self.src[i]
}

fn peek(self: &Parser) u8 {
    return self.peek_at(0)
}

fn bump(self: &Parser, n: usize) {
    self.pos = self.pos + n
}

fn starts(self: &Parser, s: String) bool {
    return starts_with(self.src[self.pos..self.src.len], s)
}

fn eat(self: &Parser, c: u8) bool {
    if self.peek() != c or self.at_end() {
        return false
    }
    self.bump(1)
    return true
}

fn expect(self: &Parser, c: u8) bool {
    if self.eat(c) {
        return true
    }
    self.fail(
        if self.at_end() { TomlErrorKind.UnexpectedEnd } else { TomlErrorKind.UnexpectedChar },
    )
    return false
}

fn skip_blanks(self: &Parser) {
    while self.peek() == ' ' or self.peek() == '\t' {
        self.bump(1)
    }
}

fn at_newline(self: &Parser) bool {
    return self.peek() == '\n' or (self.peek() == '\r' and self.peek_at(1) == '\n')
}

fn eat_newline(self: &Parser) bool {
    if self.peek() == '\n' {
        self.bump(1)
        return true
    }
    if self.peek() == '\r' and self.peek_at(1) == '\n' {
        self.bump(2)
        return true
    }
    return false
}

fn skip_comment(self: &Parser) {
    if self.peek() != '#' {
        return
    }
    while !self.at_end() and !self.at_newline() {
        self.bump(1)
    }
}

// Blanks, comments and line breaks, as between array elements.
fn skip_space(self: &Parser) {
    loop {
        self.skip_blanks()
        self.skip_comment()
        if !self.eat_newline() {
            return
        }
    }
}

// The rest of a line after a key/value pair or a header: blanks, a comment, then a line break or
// the end of input.
fn end_line(self: &Parser) {
    self.skip_blanks()
    self.skip_comment()
    if self.at_end() or self.eat_newline() {
        return
    }
    self.fail(TomlErrorKind.UnexpectedChar)
}

// ---- Paths and table origins ----

// A key segment: `k<len>:<bytes>`, so no key spelling can collide with another path.
fn push_key(self: &Parser, key: String) {
    self.path.append_byte('k')
    self.path.append(key.len)
    self.path.append_byte(':')
    self.path.append(key)
}

// An array element segment: `i<index>;`.
fn push_index(self: &Parser, index: usize) {
    self.path.append_byte('i')
    self.path.append(index)
    self.path.append_byte(';')
}

fn origin(self: &Parser) u8 {
    return self.origins.get(self.path.as_view()) ?? 0
}

fn set_origin(self: &Parser, how: u8) {
    self.origins.set(self.path.as_view(), how)
}

// ---- Document ----

fn parse_document(self: &Parser, root: &Value) {
    let table = root
    loop {
        self.skip_space()
        if self.at_end() or self.failed() {
            return
        }
        if self.peek() == '[' {
            const next = self.header(root)
            if next.is_none() {
                return
            }
            table = next.unwrap()
        } else {
            const base = self.path.len
            self.key_value(table)
            self.path.truncate(base)
        }
        if self.failed() {
            return
        }
        self.end_line()
    }
}

// `[a.b]` or `[[a.b]]`: the table the following pairs go into.
fn header(self: &Parser, root: &Value) &Value? {
    const header_start = self.pos
    const is_array = self.peek_at(1) == '['
    self.bump(if is_array { 2 } else { 1 })
    self.skip_blanks()
    let keys = self.parse_key()
    defer keys.deinit()
    if self.failed() {
        return null
    }
    self.skip_blanks()
    if !self.expect(']') {
        return null
    }
    if is_array and !self.expect(']') {
        return null
    }

    // Errors in the key path point at the header.
    const header_end = self.pos
    self.pos = header_start
    self.path.clear()
    let node = root
    for i in 0..keys.len {
        const key = keys[i].view
        const last = i + 1 == keys.len
        const step = if !last {
            self.enter_parent(node, key)
        } else if is_array {
            self.enter_array_table(node, key)
        } else {
            self.enter_header_table(node, key)
        }
        if step.is_none() {
            return null
        }
        node = step.unwrap()
    }
    self.pos = header_end
    return Some(node)
}

// A header's leading key: an existing table, the last table of an array of tables, or a new table
// defined later or never.
fn enter_parent(self: &Parser, node: &Value, key: String) &Value? {
    const map = node.as_map().unwrap()
    self.push_key(key)
    if !map.contains(key) {
        map.set(key, value_map(self.allocator))
        self.set_origin(IMPLICIT)
        return map.get_ref(key)
    }
    const how = self.origin()
    const child = map.get_ref(key).unwrap()
    return child.* match {
        Map(_) => {
            if how & INLINE != 0 {
                self.fail(TomlErrorKind.TableRedefined)
                return null
            }
            Some(child)
        }
        Array(items) => {
            if how & ARRAY_OF_TABLES == 0 or items.len == 0 {
                self.fail(TomlErrorKind.NotATable)
                return null
            }
            self.push_index(items.len - 1)
            items.last_ref()
        }
        else => {
            self.fail(TomlErrorKind.NotATable)
            null
        }
    }
}

// The table a `[header]` defines: new, or one only implied so far.
fn enter_header_table(self: &Parser, node: &Value, key: String) &Value? {
    const map = node.as_map().unwrap()
    self.push_key(key)
    if !map.contains(key) {
        map.set(key, value_map(self.allocator))
        self.set_origin(BY_HEADER)
        return map.get_ref(key)
    }
    const how = self.origin()
    const child = map.get_ref(key).unwrap()
    const defined = how & (BY_HEADER | BY_DOTTED_KEY | INLINE) != 0
    if !child.is_map() or defined {
        self.fail(TomlErrorKind.TableRedefined)
        return null
    }
    self.set_origin(how | BY_HEADER)
    return Some(child)
}

// A new element of the array of tables a `[[header]]` names.
fn enter_array_table(self: &Parser, node: &Value, key: String) &Value? {
    const map = node.as_map().unwrap()
    self.push_key(key)
    if !map.contains(key) {
        map.set(key, value_array(self.allocator))
        self.set_origin(ARRAY_OF_TABLES)
    }
    const child = map.get_ref(key).unwrap()
    if self.origin() & ARRAY_OF_TABLES == 0 {
        self.fail(TomlErrorKind.TableRedefined)
        return null
    }
    child.push(value_map(self.allocator))
    self.push_index(child.len() - 1)
    return child.at(child.len() - 1)
}

// `a.b.c = value` into `table`, whose path is `self.path`.
fn key_value(self: &Parser, table: &Value) {
    const key_start = self.pos
    let keys = self.parse_key()
    defer keys.deinit()
    if self.failed() {
        return
    }
    self.skip_blanks()
    if !self.expect('=') {
        return
    }
    self.skip_blanks()

    // Errors in the key path point at the key.
    const value_start = self.pos
    self.pos = key_start
    let node = table
    for i in 0..keys.len - 1 {
        const step = self.enter_dotted(node, keys[i].view)
        if step.is_none() {
            return
        }
        node = step.unwrap()
    }
    const key = keys[keys.len - 1].view
    const map = node.as_map().unwrap()
    if map.contains(key) {
        self.fail(TomlErrorKind.DuplicateKey)
        return
    }
    self.pos = value_start
    self.push_key(key)
    let parsed = self.parse_value()
    if parsed.is_none() {
        return
    }
    let v = parsed.unwrap()
    if v.is_map() {
        self.set_origin(INLINE)
    }
    map.set(key, v)
}

// A dotted key's leading part: a table that dotted keys created, or a new one.
fn enter_dotted(self: &Parser, node: &Value, key: String) &Value? {
    const map = node.as_map().unwrap()
    self.push_key(key)
    if !map.contains(key) {
        map.set(key, value_map(self.allocator))
        self.set_origin(BY_DOTTED_KEY)
        return map.get_ref(key)
    }
    const child = map.get_ref(key).unwrap()
    if !child.is_map() {
        self.fail(TomlErrorKind.NotATable)
        return null
    }
    if self.origin() != BY_DOTTED_KEY {
        self.fail(TomlErrorKind.TableRedefined)
        return null
    }
    return Some(child)
}

// ---- Keys ----

// `a`, `"quoted"`, `'literal'`, joined by dots. Empty on error.
fn parse_key(self: &Parser) List(OwnedString) {
    let keys: List(OwnedString) = list(0, self.allocator)
    loop {
        self.skip_blanks()
        const part = self.peek() match {
            '"' => self.basic_string(false)
            '\'' => self.literal_string(false)
            else => self.bare_key()
        }
        if part.is_none() {
            keys.clear()
            return keys
        }
        keys.push(part.unwrap())
        self.skip_blanks()
        if !self.eat('.') {
            return keys
        }
    }
    return keys
}

fn is_bare_key_char(c: u8) bool {
    return c match {
        'A'..='Z' | 'a'..='z' | '0'..='9' | '_' | '-' => true
        else => false
    }
}

fn bare_key(self: &Parser) OwnedString? {
    const start = self.pos
    while !self.at_end() and is_bare_key_char(self.peek()) {
        self.bump(1)
    }
    if self.pos == start {
        self.fail(
            if self.at_end() { TomlErrorKind.UnexpectedEnd } else { TomlErrorKind.UnexpectedChar },
        )
        return null
    }
    return Some(from_view(self.src[start..self.pos], self.allocator))
}

// ---- Values ----

fn parse_value(self: &Parser) Value? {
    if self.at_end() {
        self.fail(TomlErrorKind.UnexpectedEnd)
        return null
    }
    return self.peek() match {
        '"' => self.string_value(self.basic_string(true))
        '\'' => self.string_value(self.literal_string(true))
        '[' => self.array()
        '{' => self.inline_table()
        't' => self.word("true", Value.Bool(true))
        'f' => self.word("false", Value.Bool(false))
        else => self.number_or_date()
    }
}

fn string_value(self: &Parser, s: move OwnedString?) Value? {
    if s.is_none() {
        return null
    }
    return Some(Value.Str(s.unwrap()))
}

fn word(self: &Parser, w: String, v: move Value) Value? {
    if !self.starts(w) {
        self.fail(TomlErrorKind.UnexpectedChar)
        return null
    }
    self.bump(w.len)
    return Some(move v)
}

fn array(self: &Parser) Value? {
    self.bump(1)
    let items = value_array(self.allocator)
    const base = self.path.len
    loop {
        self.skip_space()
        if self.eat(']') {
            return Some(move items)
        }
        self.push_index(items.len())
        const v = self.parse_value()
        self.path.truncate(base)
        if v.is_none() {
            items.deinit()
            return null
        }
        let item = v.unwrap()
        items.push(item)
        self.skip_space()
        if self.eat(']') {
            return Some(move items)
        }
        if !self.expect(',') {
            items.deinit()
            return null
        }
    }
    return null
}

// `{ a = 1, b.c = 2 }` on one line, no trailing comma.
fn inline_table(self: &Parser) Value? {
    self.bump(1)
    let table = value_map(self.allocator)
    self.skip_blanks()
    if self.eat('}') {
        return Some(move table)
    }
    const base = self.path.len
    loop {
        self.skip_blanks()
        self.key_value(&table)
        self.path.truncate(base)
        if self.failed() {
            table.deinit()
            return null
        }
        self.skip_blanks()
        if self.eat('}') {
            return Some(move table)
        }
        if !self.expect(',') {
            table.deinit()
            return null
        }
    }
    return null
}

// ---- Strings ----

// `"..."`, or `"""..."""` where `multiline` allows it.
fn basic_string(self: &Parser, multiline: bool) OwnedString? {
    const is_multi = multiline and self.starts("\"\"\"")
    self.bump(if is_multi { 3 } else { 1 })
    if is_multi {
        self.eat_newline()
    }
    let sb = string_builder(16, self.allocator)
    defer sb.deinit()
    loop {
        if self.at_end() {
            self.fail(TomlErrorKind.UnexpectedEnd)
            return null
        }
        const c = self.peek()
        if c == '"' {
            if !is_multi {
                self.bump(1)
                return Some(sb.to_string())
            }
            if self.close_multiline('"', &sb) {
                return Some(sb.to_string())
            }
            continue
        }
        if c == '\\' {
            if !self.escape(&sb, is_multi) {
                return null
            }
            continue
        }
        if !self.string_char(&sb, is_multi) {
            return null
        }
    }
    return null
}

// `'...'`, or `'''...'''` where `multiline` allows it. No escapes.
fn literal_string(self: &Parser, multiline: bool) OwnedString? {
    const is_multi = multiline and self.starts("'''")
    self.bump(if is_multi { 3 } else { 1 })
    if is_multi {
        self.eat_newline()
    }
    let sb = string_builder(16, self.allocator)
    defer sb.deinit()
    loop {
        if self.at_end() {
            self.fail(TomlErrorKind.UnexpectedEnd)
            return null
        }
        if self.peek() == '\'' {
            if !is_multi {
                self.bump(1)
                return Some(sb.to_string())
            }
            if self.close_multiline('\'', &sb) {
                return Some(sb.to_string())
            }
            continue
        }
        if !self.string_char(&sb, is_multi) {
            return null
        }
    }
    return null
}

// At a quote in a multi-line string: a run of three to five closes it, the extra one or two being
// content; a shorter run is content. Returns whether the string closed.
fn close_multiline(self: &Parser, quote: u8, sb: &StringBuilder) bool {
    let run: usize = 0
    while run < 5 and self.peek_at(run) == quote {
        run = run + 1
    }
    if run < 3 {
        for _i in 0..run {
            sb.append_byte(quote)
        }
        self.bump(run)
        return false
    }
    for _i in 0..run - 3 {
        sb.append_byte(quote)
    }
    self.bump(run)
    return true
}

// One unescaped character: a line break only in a multi-line string, no other control character but
// tab.
fn string_char(self: &Parser, sb: &StringBuilder, is_multi: bool) bool {
    if self.at_newline() {
        if !is_multi {
            self.fail(TomlErrorKind.UnexpectedChar)
            return false
        }
        self.eat_newline()
        sb.append_byte('\n')
        return true
    }
    const c = self.peek()
    const is_control = (c < 0x20 and c != '\t') or c == 0x7F
    if is_control {
        self.fail(TomlErrorKind.UnexpectedChar)
        return false
    }
    sb.append_byte(c)
    self.bump(1)
    return true
}

// A backslash escape, or in a multi-line string a line-ending backslash, which drops the line break
// and the blanks and line breaks after it.
fn escape(self: &Parser, sb: &StringBuilder, is_multi: bool) bool {
    self.bump(1)
    if is_multi and self.line_ending_backslash() {
        return true
    }
    const c = self.peek()
    if self.at_end() {
        self.fail(TomlErrorKind.UnexpectedEnd)
        return false
    }
    self.bump(1)
    return c match {
        'b' => append_ok(sb, 8 as u8)
        't' => append_ok(sb, '\t')
        'n' => append_ok(sb, '\n')
        'f' => append_ok(sb, 12 as u8)
        'r' => append_ok(sb, '\r')
        '"' => append_ok(sb, '"')
        '\\' => append_ok(sb, '\\')
        'u' => self.unicode_escape(sb, 4)
        'U' => self.unicode_escape(sb, 8)
        else => {
            self.fail(TomlErrorKind.InvalidEscape)
            false
        }
    }
}

fn append_ok(sb: &StringBuilder, c: u8) bool {
    sb.append_byte(c)
    return true
}

// After a backslash: blanks to the end of the line, then every blank and line break that follows.
// Leaves the position alone and returns false when the backslash is not at a line end.
fn line_ending_backslash(self: &Parser) bool {
    let i: usize = 0
    while self.peek_at(i) == ' ' or self.peek_at(i) == '\t' {
        i = i + 1
    }
    const at_break = self.peek_at(i) == '\n' or (self.peek_at(i) == '\r'
        and self.peek_at(i + 1) == '\n')
    if !at_break {
        return false
    }
    self.bump(i)
    self.skip_whitespace_and_newlines()
    return true
}

fn skip_whitespace_and_newlines(self: &Parser) {
    loop {
        self.skip_blanks()
        if !self.eat_newline() {
            return
        }
    }
}

// `digits` hex digits naming a Unicode scalar value, written as UTF-8.
fn unicode_escape(self: &Parser, sb: &StringBuilder, digits: usize) bool {
    let cp: u32 = 0
    for _i in 0..digits {
        const d = hex_value(self.peek())
        if d.is_none() {
            self.fail(TomlErrorKind.InvalidUnicode)
            return false
        }
        cp = cp * 16 + d.unwrap()
        self.bump(1)
    }
    const is_surrogate = cp >= 0xD800 and cp <= 0xDFFF
    if is_surrogate or cp > 0x10FFFF {
        self.fail(TomlErrorKind.InvalidUnicode)
        return false
    }
    let utf8 = [0u8; 4]
    const n = encode_char(cp as char, utf8)
    sb.append_bytes(utf8[0..n])
    return true
}

fn hex_value(c: u8) u32? {
    return c match {
        '0'..='9' => Some((c - '0') as u32)
        'a'..='f' => Some((c - 'a' + 10) as u32)
        'A'..='F' => Some((c - 'A' + 10) as u32)
        else => null
    }
}

// ---- Numbers and dates ----

fn is_token_char(c: u8) bool {
    return c match {
        'A'..='Z' | 'a'..='z' | '0'..='9' | '_' | '+' | '-' | '.' | ':' => true
        else => false
    }
}

// The number or date-time token ahead. A date followed by a space and a digit continues as a
// date-time (`1979-05-27 07:32:00Z`).
fn scan_token(self: &Parser) String {
    const start = self.pos
    while is_token_char(self.peek()) and !self.at_end() {
        self.bump(1)
    }
    const looks_like_date = self.pos - start == 10 and self.src[start + 4] == '-'
    const time_follows = self.peek() == ' ' and is_digit(self.peek_at(1))
    if looks_like_date and time_follows {
        self.bump(1)
        while is_token_char(self.peek()) and !self.at_end() {
            self.bump(1)
        }
    }
    return self.src[start..self.pos]
}

fn is_digit(c: u8) bool {
    return c >= '0' and c <= '9'
}

fn number_or_date(self: &Parser) Value? {
    const token = self.scan_token()
    if token.len == 0 {
        self.fail(TomlErrorKind.UnexpectedChar)
        return null
    }
    const kind = temporal_kind(token)
    if kind != ValueKind.Str {
        return Some(read_temporal(token, kind))
    }
    if contains(token, ":") or (token.len >= 5 and token[4] == '-' and is_digit(token[0])) {
        self.fail(TomlErrorKind.InvalidDate)
        return null
    }
    const v = number_value(token)
    if v.is_none() {
        self.fail(TomlErrorKind.InvalidNumber)
    }
    return v
}

// A token `temporal_kind` classified, as that kind.
fn read_temporal(token: String, kind: ValueKind) Value {
    return kind match {
        Date => Value.Date(parse_date(token).unwrap())
        Time => Value.Time(parse_time(token).unwrap())
        OffsetDateTime => Value.OffsetDateTime(parse_offset_datetime(token).unwrap())
        else => Value.DateTime(parse_datetime(token).unwrap())
    }
}

// A TOML integer or float, or null when `token` is not one.
fn number_value(token: String) Value? {
    const body = if token[0] == '+' or token[0] == '-' { token[1..token.len] } else { token }
    const negative = token[0] == '-'
    if body == "inf" {
        return Some(Value.Float(if negative { 0.0 - infinity() } else { infinity() }))
    }
    if body == "nan" {
        return Some(Value.Float(not_a_number()))
    }
    const signed = body.len != token.len
    if body.len > 2 and body[0] == '0' {
        const base: u8 = body[1] match { 'x' => 16, 'o' => 8, 'b' => 2, else => 0 }
        if base != 0 {
            if signed {
                return null
            }
            return radix_int(body[2..body.len], base)
        }
    }
    let digits = [0u8; 64]
    const n = strip_underscores(body, digits)
    if n.is_none() {
        return null
    }
    const clean = digits[0..n.unwrap()] as String
    if is_float_text(clean) {
        return float_value(token[0] == '-', clean)
    }
    if clean.len > 1 and clean[0] == '0' {
        return null
    }
    return decimal_int(negative, clean)
}

// Computed at run time: the seed compiler writes a division by a literal zero into the C source,
// where MSVC refuses it (fixed in the C backend; usable here once a promote carries the fix).
fn infinity() f64 {
    let zero = 0.0
    return 1.0 / zero
}

fn not_a_number() f64 {
    let zero = 0.0
    return zero / zero
}

// `s` with its underscores removed into `out`, each underscore having a digit on both sides, or
// null when one does not or `s` does not fit.
fn strip_underscores(s: String, out: u8[]) usize? {
    if s.len == 0 or s.len > out.len {
        return null
    }
    let n: usize = 0
    for i in 0..s.len {
        if s[i] != '_' {
            out[n] = s[i]
            n = n + 1
            continue
        }
        const between = i > 0 and i + 1 < s.len and is_hex_digit(s[i - 1])
            and is_hex_digit(s[i + 1])
        if !between {
            return null
        }
    }
    return Some(n)
}

fn is_hex_digit(c: u8) bool {
    return hex_value(c).is_some()
}

fn is_float_text(s: String) bool {
    for i in 0..s.len {
        if s[i] == '.' or s[i] == 'e' or s[i] == 'E' {
            return true
        }
    }
    return false
}

// A decimal float: an integer part without leading zeros, then a fraction with digits on both sides
// of the point, an exponent, or both.
fn float_value(negative: bool, s: String) Value? {
    let int_len: usize = 0
    while int_len < s.len and is_digit(s[int_len]) {
        int_len = int_len + 1
    }
    if int_len == 0 or (int_len > 1 and s[0] == '0') {
        return null
    }
    if int_len < s.len and s[int_len] == '.' {
        const after = int_len + 1
        if after >= s.len or !is_digit(s[after]) {
            return null
        }
    }
    const r = parse_f64(s.as_raw_bytes())
    if r.is_err() or r.unwrap().1 != s.len {
        return null
    }
    const v = r.unwrap().0
    return Some(Value.Float(if negative { -v } else { v }))
}

fn decimal_int(negative: bool, s: String) Value? {
    for i in 0..s.len {
        if !is_digit(s[i]) {
            return null
        }
    }
    const r = parse_u64(s.as_raw_bytes())
    if r.is_err() or r.unwrap().1 != s.len {
        return null
    }
    const magnitude = r.unwrap().0
    const limit: u64 = if negative { 9223372036854775808 } else { 9223372036854775807 }
    if magnitude > limit {
        return null
    }
    if negative {
        return Some(Value.Int(0 - (magnitude - 1) as i64 - 1))
    }
    return Some(Value.Int(magnitude as i64))
}

fn radix_int(s: String, base: u8) Value? {
    let digits = [0u8; 80]
    const n = strip_underscores(s, digits)
    if n.is_none() {
        return null
    }
    const clean = digits[0..n.unwrap()] as String
    const r = parse_u64(clean.as_raw_bytes(), base)
    if r.is_err() or r.unwrap().1 != clean.len {
        return null
    }
    const magnitude = r.unwrap().0
    if magnitude > 9223372036854775807 {
        return null
    }
    return Some(Value.Int(magnitude as i64))
}

// =============================================================================
// Writing
// =============================================================================

// Write a map as a TOML document.
pub fn to_toml(value: &Value, w: Writer) Result((), TomlError) {
    let tw = TomlWriter { w = w, error = null, wrote = false }
    let path: List(String) = list(0)
    defer path.deinit()
    const root = value.as_map()
    if root.is_none() {
        return Err(writing_error(TomlErrorKind.RootNotTable))
    }
    tw.write_table(root.unwrap(), &path)
    if tw.error.is_some() {
        return Err(writing_error(tw.error.unwrap()))
    }
    return Ok(())
}

// A map as TOML text.
pub fn to_toml(value: &Value, allocator: &Allocator? = null) Result(OwnedString, TomlError) {
    let sb = string_builder(64, allocator)
    defer sb.deinit()
    to_toml(value, sb.writer())?
    return Ok(sb.to_string())
}

fn writing_error(kind: TomlErrorKind) TomlError {
    return TomlError { kind = kind, line = 0, column = 0 }
}

type TomlWriter = struct {
    w: Writer
    error: TomlErrorKind?
    // Whether anything has been written, for the blank line before a header.
    wrote: bool
}

fn fail(self: &TomlWriter, kind: TomlErrorKind) {
    if self.error.is_none() {
        self.error = Some(kind)
    }
}

// An array written as `[[header]]` sections: one or more elements, every one a map.
fn is_table_array(v: &Value) bool {
    const items = v.as_array()
    if items.is_none() or items.unwrap().len == 0 {
        return false
    }
    for i in 0..items.unwrap().len {
        if !items.unwrap()[i].is_map() {
            return false
        }
    }
    return true
}

fn is_section(v: &Value) bool {
    return v.is_map() or is_table_array(v)
}

// A table's plain keys, then its sub-tables, then its arrays of tables. `path` is the table's key
// path.
fn write_table(self: &TomlWriter, table: &OrderedDict(OwnedString, Value), path: &List(String)) {
    for e in table {
        if !is_section(&e.value) {
            self.write_key(e.key.view)
            self.w.write_str(" = ")
            self.write_inline(&e.value)
            self.w.write_byte('\n')
            self.wrote = true
        }
    }
    for e in table {
        if e.value.is_map() {
            path.push(e.key.view)
            const sub = e.value.as_map().unwrap()
            if self.needs_header(sub) {
                self.write_header(path, false)
            }
            self.write_table(sub, path)
            const _k = path.pop()
        }
    }
    for e in table {
        if is_table_array(&e.value) {
            path.push(e.key.view)
            const items = e.value.as_array().unwrap()
            for i in 0..items.len {
                self.write_header(path, true)
                self.write_table(items[i].as_map().unwrap(), path)
            }
            const _k = path.pop()
        }
    }
}

// A table that holds only sub-tables is implied by their headers and gets none of its own.
fn needs_header(self: &TomlWriter, table: &OrderedDict(OwnedString, Value)) bool {
    if table.len() == 0 {
        return true
    }
    for e in table {
        if !is_section(&e.value) {
            return true
        }
    }
    return false
}

fn write_header(self: &TomlWriter, path: &List(String), array: bool) {
    if self.wrote {
        self.w.write_byte('\n')
    }
    self.w.write_str(if array { "[[" } else { "[" })
    for i in 0..path.len {
        if i > 0 {
            self.w.write_byte('.')
        }
        self.write_key(path[i])
    }
    self.w.write_str(if array { "]]\n" } else { "]\n" })
    self.wrote = true
}

fn write_key(self: &TomlWriter, key: String) {
    let bare = key.len > 0
    for i in 0..key.len {
        if !is_bare_key_char(key[i]) {
            bare = false
        }
    }
    if bare {
        self.w.write_str(key)
        return
    }
    self.write_string(key)
}

fn write_string(self: &TomlWriter, s: String) {
    self.w.write_byte('"')
    for i in 0..s.len {
        const c = s[i]
        c match {
            '"' => self.w.write_str("\\\"")
            '\\' => self.w.write_str("\\\\")
            '\n' => self.w.write_str("\\n")
            '\r' => self.w.write_str("\\r")
            '\t' => self.w.write_str("\\t")
            8 => self.w.write_str("\\b")
            12 => self.w.write_str("\\f")
            0..=0x1F | 0x7F => {
                self.w.write_str("\\u00")
                const hi = (c >> 4) & 0x0F
                const lo = c & 0x0F
                self.w.write_byte(if hi < 10 { '0' + hi } else { 'A' + hi - 10 })
                self.w.write_byte(if lo < 10 { '0' + lo } else { 'A' + lo - 10 })
            }
            else => self.w.write_byte(c)
        }
    }
    self.w.write_byte('"')
}

fn write_float(self: &TomlWriter, v: f64) {
    if v != v {
        self.w.write_str("nan")
        return
    }
    if v != 0.0 and v * 0.5 == v {
        self.w.write_str(if v < 0.0 { "-inf" } else { "inf" })
        return
    }
    let buf = [0u8; 32]
    const n = format_f64_shortest(v, buf).unwrap()
    self.w.write(buf[0..n])
    if !is_float_text(buf[0..n] as String) {
        self.w.write_str(".0")
    }
}

// A value on the right of `=` or inside an array: arrays and maps inline.
fn write_inline(self: &TomlWriter, v: &Value) {
    v.* match {
        Null => self.fail(TomlErrorKind.NullValue)
        Bool(b) => self.w.write_str(if b { "true" } else { "false" })
        Int(n) => self.w.write_int(n)
        Float(f) => self.write_float(f)
        Str(s) => self.write_string(s.view)
        Date(d) => d.format(self.w, "")
        Time(t) => t.format(self.w, "")
        DateTime(dt) => dt.format(self.w, "")
        OffsetDateTime(odt) => odt.format(self.w, "")
        Array(items) => {
            self.w.write_byte('[')
            for i in 0..items.len {
                if i > 0 {
                    self.w.write_str(", ")
                }
                self.write_inline(&items[i])
            }
            self.w.write_byte(']')
        }
        Map(d) => {
            self.w.write_byte('{')
            let first = true
            for e in d {
                self.w.write_str(if first { " " } else { ", " })
                first = false
                self.write_key(e.key.view)
                self.w.write_str(" = ")
                self.write_inline(&e.value)
            }
            self.w.write_str(if first { "}" } else { " }" })
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

fn toml_error(text: String) TomlErrorKind {
    const r = parse_toml(text)
    return r match {
        Ok(v) => {
            v.deinit()
            panic("parsed")
        }
        Err(e) => e.kind
    }
}

test "scalars of every kind" {
    let doc = parse_toml(
        "s = \"a\\tb\\u00e9\"\nlit = 'C:\\path'\ni = -1_000\nh = 0xff\no = 0o17\nb = 0b101\nf = 6.25e-1\nyes = true\nday = 1979-05-27\nat = 1979-05-27T07:32:00Z\nlocal = 1979-05-27 07:32:00.5\nclock = 07:32:00\nbig = inf\n",
    ).unwrap()
    defer doc.deinit()
    assert_eq(doc.get("s").unwrap().as_string().unwrap(), "a\tb\u00e9", "basic string escapes")
    assert_eq(
        doc.get("lit").unwrap().as_string().unwrap(),
        "C:\\path",
        "literal string keeps backslashes",
    )
    assert_eq(doc.get("i").unwrap().as_i64().unwrap(), -1000i64, "underscored int")
    assert_eq(doc.get("h").unwrap().as_i64().unwrap(), 255i64, "hex")
    assert_eq(doc.get("o").unwrap().as_i64().unwrap(), 15i64, "octal")
    assert_eq(doc.get("b").unwrap().as_i64().unwrap(), 5i64, "binary")
    assert_eq(doc.get("f").unwrap().as_f64().unwrap(), 0.625, "float with exponent")
    assert_eq(doc.get("yes").unwrap().as_bool().unwrap(), true, "bool")
    assert_true(doc.get("day").unwrap().as_date().is_some(), "local date")
    assert_true(doc.get("at").unwrap().as_offset_datetime().is_some(), "offset date-time")
    assert_true(
        doc.get("local").unwrap().as_datetime().is_some(),
        "local date-time, space separated",
    )
    assert_true(doc.get("clock").unwrap().as_time().is_some(), "local time")
    assert_true(doc.get("big").unwrap().as_f64().unwrap() > 1.0e308, "inf")
}

test "multi-line strings trim the first line break and line-ending backslashes" {
    let doc = parse_toml(
        "a = \"\"\"\none\ntwo\"\"\"\nb = \"\"\"x \\\n    y\"\"\"\nc = '''\nraw \\n'''\nd = \"\"\"q\"\"\"\"\n",
    ).unwrap()
    defer doc.deinit()
    assert_eq(doc.get("a").unwrap().as_string().unwrap(), "one\ntwo", "first newline trimmed")
    assert_eq(doc.get("b").unwrap().as_string().unwrap(), "x y", "line-ending backslash")
    assert_eq(doc.get("c").unwrap().as_string().unwrap(), "raw \\n", "literal multi-line")
    assert_eq(doc.get("d").unwrap().as_string().unwrap(), "q\"", "quote before the closing run")
}

test "tables, dotted keys, inline tables and arrays of tables" {
    let doc = parse_toml(
        "title = \"x\"\n[owner]\nname = \"Tom\"\n[a.b]\nc = 1\n[a]\nd = 2\n[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n[fruit.apple.texture]\nsmooth = true\n[[products]]\nname = \"Hammer\"\n[[products]]\nname = \"Nail\"\n[products.dims]\nlen = 3\n[deps]\nflang_core = { path = \"../flang_core\" }\nlist = [1, [2, 3], { k = 'v' }, ]\n",
    ).unwrap()
    defer doc.deinit()
    assert_eq(doc.get("owner").unwrap().get("name").unwrap().as_string().unwrap(), "Tom", "table")
    assert_eq(
        doc.get("a").unwrap().get("b").unwrap().get("c").unwrap().as_i64().unwrap(),
        1i64,
        "nested",
    )
    assert_eq(
        doc.get("a").unwrap().get("d").unwrap().as_i64().unwrap(),
        2i64,
        "implicit table defined later",
    )
    const apple = doc.get("fruit").unwrap().get("apple").unwrap()
    assert_eq(apple.get("color").unwrap().as_string().unwrap(), "red", "dotted key")
    assert_true(
        apple.get("texture").unwrap().get("smooth").unwrap().as_bool().unwrap(),
        "header under dotted",
    )
    const products = doc.get("products").unwrap()
    assert_eq(products.len(), 2 as usize, "two products")
    assert_eq(
        products.at(1).unwrap().get("dims").unwrap().get("len").unwrap().as_i64().unwrap(),
        3i64,
        "sub-table of the last element",
    )
    const dep = doc.get("deps").unwrap().get("flang_core").unwrap()
    assert_eq(dep.get("path").unwrap().as_string().unwrap(), "../flang_core", "inline table")
    assert_eq(
        doc.get("deps").unwrap().get("list").unwrap().len(),
        3 as usize,
        "mixed array, trailing comma",
    )
    const keys = doc.as_map().unwrap()
    assert_true(keys.entry_at(0).unwrap().key.view == "title", "document order")
    assert_true(keys.entry_at(1).unwrap().key.view == "owner", "document order")
}

test "invalid documents report their error" {
    assert_true(toml_error("a = 1\na = 2\n") == TomlErrorKind.DuplicateKey, "duplicate key")
    assert_true(toml_error("[a]\n[a]\n") == TomlErrorKind.TableRedefined, "table twice")
    assert_true(toml_error("a = {}\n[a]\n") == TomlErrorKind.TableRedefined, "inline reopened")
    assert_true(
        toml_error("[a.b.c]\nz = 9\n[a]\nb.c.t = 1\n") == TomlErrorKind.TableRedefined,
        "dotted into header table",
    )
    assert_true(
        toml_error("[fruit]\napple.color = 1\n[fruit.apple]\n") == TomlErrorKind.TableRedefined,
        "header over dotted",
    )
    assert_true(
        toml_error("a = [1]\n[[a]]\n") == TomlErrorKind.TableRedefined,
        "static array extended",
    )
    assert_true(
        toml_error("a = 1\nb.c = 2\na.d = 3\n") == TomlErrorKind.NotATable,
        "key through a value",
    )
    assert_true(toml_error("a = 01\n") == TomlErrorKind.InvalidNumber, "leading zero")
    assert_true(toml_error("a = 1__0\n") == TomlErrorKind.InvalidNumber, "double underscore")
    assert_true(toml_error("a = 1.\n") == TomlErrorKind.InvalidNumber, "bare point")
    assert_true(
        toml_error("a = 9223372036854775808\n") == TomlErrorKind.InvalidNumber,
        "i64 overflow",
    )
    assert_true(toml_error("a = 1979-13-01\n") == TomlErrorKind.InvalidDate, "month 13")
    assert_true(toml_error("a = \"\\q\"\n") == TomlErrorKind.InvalidEscape, "escape")
    assert_true(toml_error("a = \"\\uD800\"\n") == TomlErrorKind.InvalidUnicode, "surrogate")
    assert_true(toml_error("a = \"x\n") == TomlErrorKind.UnexpectedChar, "line break in a string")
    assert_true(toml_error("a = 1 b = 2\n") == TomlErrorKind.UnexpectedChar, "two pairs on a line")
    assert_true(
        toml_error("a = { b = 1, }\n") == TomlErrorKind.UnexpectedChar,
        "inline trailing comma",
    )
    assert_true(toml_error("a =\n") == TomlErrorKind.UnexpectedChar, "missing value")
    const r = parse_toml("x = 1\n\ny = @\n")
    assert_true(r.is_err(), "error")
    const e = r.unwrap_err()
    assert_eq(e.line, 3 as usize, "line")
    assert_eq(e.column, 5 as usize, "column")
    const dup = parse_toml("a = 1\n  a = 2\n").unwrap_err()
    assert_eq(dup.column, 3 as usize, "a duplicate key points at the key")
    const twice = parse_toml("[t]\n[t]\n").unwrap_err()
    assert_eq(twice.line, 2 as usize, "a redefined table points at its header")
    assert_eq(twice.column, 1 as usize, "at the bracket")
}

test "to_toml writes plain keys before tables and reads back the same tree" {
    let doc = value_map()
    defer doc.deinit()
    let server = value_map()
    server.set("host", value_str("a b"))
    server.set("port", Value.Int(8080))
    doc.set("server", server)
    doc.set("name", value_str("x\"y"))
    doc.set("ratio", Value.Float(2.0))
    let tags = value_array()
    tags.push(value_str("t"))
    tags.push(Value.Date(date(2026, Month.October, 14).unwrap()))
    doc.set("tags", tags)
    let items = value_array()
    let first = value_map()
    first.set("id", Value.Int(1))
    items.push(first)
    let second = value_map()
    second.set("id", Value.Int(2))
    items.push(second)
    doc.set("items", items)

    let text = to_toml(&doc).unwrap()
    defer text.deinit()
    assert_eq(
        text.view,
        "name = \"x\\\"y\"\nratio = 2.0\ntags = [\"t\", 2026-10-14]\n\n[server]\nhost = \"a b\"\nport = 8080\n\n[[items]]\nid = 1\n\n[[items]]\nid = 2\n",
        "document",
    )

    let back = parse_toml(text.view).unwrap()
    defer back.deinit()
    assert_eq(
        back.get("server").unwrap().get("port").unwrap().as_i64().unwrap(),
        8080i64,
        "round trip",
    )
    assert_true(back.get("ratio").unwrap().is_float(), "float stays a float")
    assert_true(back.get("tags").unwrap().at(1).unwrap().as_date().is_some(), "date stays a date")
}

test "to_toml refuses a null and a non-map document" {
    let doc = value_map()
    defer doc.deinit()
    doc.set("n", Value.Null)
    const r = to_toml(&doc)
    assert_true(r.unwrap_err().kind == TomlErrorKind.NullValue, "null")
    const scalar = Value.Int(1)
    const s = to_toml(&scalar)
    assert_true(s.unwrap_err().kind == TomlErrorKind.RootNotTable, "not a map")
}

test "a parsed document decodes into a derived struct" {
    let doc = parse_toml("[project]\nname = \"demo\"\nversion = 3\n").unwrap()
    defer doc.deinit()
    let dec = value_decoder(doc.get("project").unwrap())
    defer dec.deinit()
    const d = dec.decoder()
    d.begin_map()
    let key = string_builder(16)
    defer key.deinit()
    assert_true(d.next_key(&key), "first key")
    let name = string_builder(16)
    defer name.deinit()
    d.decode_str(name.writer())
    assert_eq(name.as_view(), "demo", "string through the decoder")
    key.clear()
    assert_true(d.next_key(&key), "second key")
    assert_eq(d.decode_int(8), 3i64, "int through the decoder")
    assert_true(!d.next_key(&key), "no more keys")
    d.end_map()
    assert_true(!d.has_error(), "no error")
}

test "TOML and JSON convert through one tree" {
    let doc = parse_toml(
        "name = \"fq\"\n[deps]\nstd = { path = \"../std\" }\n[[bin]]\nat = 2026-10-14\n",
    ).unwrap()
    defer doc.deinit()
    let json = to_json(&doc).unwrap()
    defer json.deinit()
    assert_eq(
        json.view,
        "{\"name\":\"fq\",\"deps\":{\"std\":{\"path\":\"../std\"}},\"bin\":[{\"at\":\"2026-10-14\"}]}",
        "TOML to JSON",
    )

    let back = parse_json(json.view, json_options(DateParsing.All)).unwrap()
    defer back.deinit()
    let toml = to_toml(&back).unwrap()
    defer toml.deinit()
    assert_eq(
        toml.view,
        "name = \"fq\"\n\n[deps.std]\npath = \"../std\"\n\n[[bin]]\nat = 2026-10-14\n",
        "JSON to TOML, dates parsed back",
    )
}
