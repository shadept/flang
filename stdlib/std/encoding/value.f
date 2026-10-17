// A document tree every format reads into and writes from.
//
//   Value         null, bool, int, float, string, the four std.time kinds, array, map
//   read_value    builds a Value from any self-describing Decoder (`peek_kind`)
//   serialize     writes a Value to any Encoder
//   transcode     streams one format into another with no tree in between
//   ValueDecoder  a Decoder over a Value, for `#derive(T, deserialize)` from a parsed tree
//   ValueEncoder  an Encoder that builds a Value, for formats written from a whole tree (TOML)
//
// Maps keep their keys in insertion order (OrderedDict), so a document round-trips in the order it
// was read.

import std.allocator
import std.collections.list
import std.collections.ordered_dict
import std.encoding.codec
import std.enum
import std.interface
import std.io.writer
import std.option
import std.result
import std.string
import std.string_builder
import std.test
import std.time

pub type Value = enum {
    Null
    Bool(bool)
    Int(i64)
    Float(f64)
    Str(OwnedString)
    Date(Date)
    Time(Time)
    DateTime(DateTime)
    OffsetDateTime(OffsetDateTime)
    Array(List(Value))
    Map(OrderedDict(OwnedString, Value))
}

pub type ValueError = enum {
    // The value held is not of the kind asked for.
    TypeMismatch
    // A map entry was written with no key before it.
    MissingKey
    // A second top-level value, or a read past the last one.
    NoValue
}

#enum_utils(ValueError)

// =============================================================================
// Construction
// =============================================================================

// A string value holding a copy of `s`.
pub fn value_str(s: String, allocator: &Allocator? = null) Value {
    return Value.Str(from_view(s, allocator))
}

// An empty array.
pub fn value_array(allocator: &Allocator? = null) Value {
    let items: List(Value) = list(0, allocator)
    return Value.Array(move items)
}

// An empty map.
pub fn value_map(allocator: &Allocator? = null) Value {
    let d: OrderedDict(OwnedString, Value) = ordered_dict(allocator)
    return Value.Map(move d)
}

pub fn deinit(self: move Value) {
    self match {
        Str(s) => s.deinit()
        Array(items) => items.deinit()
        Map(d) => d.deinit()
        else => {}
    }
}

// The element form: a container releases its elements with an allocator in hand. The value carries
// its own.
pub fn deinit(self: move Value, allocator: &Allocator) {
    self.deinit()
}

// =============================================================================
// Reads
// =============================================================================

// The kind of value held.
pub fn kind(self: &Value) ValueKind {
    return self.* match {
        Null => ValueKind.Null
        Bool(_) => ValueKind.Bool
        Int(_) => ValueKind.Int
        Float(_) => ValueKind.Float
        Str(_) => ValueKind.Str
        Date(_) => ValueKind.Date
        Time(_) => ValueKind.Time
        DateTime(_) => ValueKind.DateTime
        OffsetDateTime(_) => ValueKind.OffsetDateTime
        Array(_) => ValueKind.Seq
        Map(_) => ValueKind.Map
    }
}

pub fn is_null(self: &Value) bool {
    return self.* match { Null => true, else => false }
}

pub fn is_bool(self: &Value) bool {
    return self.* match { Bool(_) => true, else => false }
}

pub fn is_int(self: &Value) bool {
    return self.* match { Int(_) => true, else => false }
}

pub fn is_float(self: &Value) bool {
    return self.* match { Float(_) => true, else => false }
}

// Whether the value is an int or a float.
pub fn is_number(self: &Value) bool {
    return self.* match { Int(_) => true, Float(_) => true, else => false }
}

pub fn is_string(self: &Value) bool {
    return self.* match { Str(_) => true, else => false }
}

pub fn is_array(self: &Value) bool {
    return self.* match { Array(_) => true, else => false }
}

pub fn is_map(self: &Value) bool {
    return self.* match { Map(_) => true, else => false }
}

pub fn as_bool(self: &Value) bool? {
    return self.* match { Bool(v) => Some(v), else => null }
}

// An int, or null for any other kind (a float included).
pub fn as_i64(self: &Value) i64? {
    return self.* match { Int(v) => Some(v), else => null }
}

// A float, or an int widened to one.
pub fn as_f64(self: &Value) f64? {
    return self.* match { Float(v) => Some(v), Int(v) => Some(v as f64), else => null }
}

// A view of the string held, valid while the value lives.
pub fn as_string(self: &Value) String? {
    return self.* match { Str(s) => Some(s.view), else => null }
}

pub fn as_date(self: &Value) Date? {
    return self.* match { Date(v) => Some(v), else => null }
}

pub fn as_time(self: &Value) Time? {
    return self.* match { Time(v) => Some(v), else => null }
}

pub fn as_datetime(self: &Value) DateTime? {
    return self.* match { DateTime(v) => Some(v), else => null }
}

pub fn as_offset_datetime(self: &Value) OffsetDateTime? {
    return self.* match { OffsetDateTime(v) => Some(v), else => null }
}

pub fn as_array(self: &Value) &List(Value)? {
    return self.* match { Array(items) => Some(&items), else => null }
}

pub fn as_map(self: &Value) &OrderedDict(OwnedString, Value)? {
    return self.* match { Map(d) => Some(&d), else => null }
}

// The value under `key` in a map, or null when absent or not a map.
pub fn get(self: &Value, key: String) &Value? {
    const d = self.as_map()?
    return d.get_ref(key)
}

// The element at `index` in an array, or null past the end or when not an array.
pub fn at(self: &Value, index: usize) &Value? {
    const items = self.as_array()?
    return items.get_ref(index)
}

// Entries in a map, elements in an array, 0 for anything else.
pub fn len(self: &Value) usize {
    return self.* match {
        Array(items) => items.len
        Map(d) => d.len()
        else => 0
    }
}

// =============================================================================
// Writes
// =============================================================================

// Sets `key` in a map to `value`. Panics when this is not a map.
pub fn set(self: &Value, key: String, value: move Value) {
    const d = self.as_map().expect("Value.set: not a map")
    d.set(key, value)
}

// Appends `value` to an array. Panics when this is not an array.
pub fn push(self: &Value, value: move Value) {
    const items = self.as_array().expect("Value.push: not an array")
    items.push(value)
}

// =============================================================================
// Encoding
// =============================================================================

// Writes the tree to `enc`. Maps write their entries in order.
pub fn serialize(self: &Value, enc: &Encoder) {
    self.* match {
        Null => { enc.encode_null() }
        Bool(b) => { enc.encode_bool(b) }
        Int(n) => { enc.encode_int(n, 8) }
        Float(n) => { enc.encode_float(n, 8) }
        Str(s) => { enc.encode_str(s.view) }
        Date(v) => { enc.encode_date(v) }
        Time(v) => { enc.encode_time(v) }
        DateTime(v) => { enc.encode_datetime(v) }
        OffsetDateTime(v) => { enc.encode_offset_datetime(v) }
        Array(items) => {
            enc.begin_seq(items.len)
            for i in 0..items.len {
                items[i].serialize(enc)
            }
            enc.end_seq()
        }
        Map(d) => {
            enc.begin_map(d.len())
            for e in d {
                enc.key(e.key.view)
                e.value.serialize(enc)
            }
            enc.end_map()
        }
    }
}

// Reads one value, whole, from a self-describing decoder. On a decoder error the tree built so far
// is returned and `dec.has_error()` is true.
pub fn read_value(dec: &Decoder, allocator: &Allocator? = null) Value {
    return dec.peek_kind() match {
        Null => {
            dec.decode_null()
            Value.Null
        }
        Bool => Value.Bool(dec.decode_bool())
        Int => Value.Int(dec.decode_int(8))
        Float => Value.Float(dec.decode_float(8))
        Str => {
            let sb = string_builder(32, allocator)
            dec.decode_str(sb.writer())
            const s = sb.to_string()
            sb.deinit()
            Value.Str(move s)
        }
        Date => Value.Date(dec.decode_date())
        Time => Value.Time(dec.decode_time())
        DateTime => Value.DateTime(dec.decode_datetime())
        OffsetDateTime => Value.OffsetDateTime(dec.decode_offset_datetime())
        Seq => read_array(dec, allocator)
        Map => read_map(dec, allocator)
        End => Value.Null
    }
}

fn read_array(dec: &Decoder, allocator: &Allocator?) Value {
    let items: List(Value) = list(0, allocator)
    dec.begin_seq()
    while !dec.has_error() {
        const next = dec.peek_kind()
        if next == ValueKind.End {
            break
        }
        items.push(read_value(dec, allocator))
    }
    dec.end_seq()
    return Value.Array(move items)
}

fn read_map(dec: &Decoder, allocator: &Allocator?) Value {
    let d: OrderedDict(OwnedString, Value) = ordered_dict(allocator)
    let key = string_builder(32, allocator)
    defer key.deinit()
    dec.begin_map()
    while !dec.has_error() {
        key.clear()
        if !dec.next_key(&key) {
            break
        }
        d.set(key.as_view(), read_value(dec, allocator))
    }
    dec.end_map()
    return Value.Map(move d)
}

// `#derive(T, deserialize)` hook: a field of type `Value` takes whatever the input holds.
pub fn deserialize(dec: &Decoder) Value {
    return read_value(dec)
}

// Reads one value from `dec` and writes it to `enc` as it goes, building no tree. Sequence and map
// lengths reach `enc` as the decoder reports them (0 when unknown).
pub fn transcode(dec: &Decoder, enc: &Encoder) {
    const _written = dec.peek_kind() match {
        Null => {
            dec.decode_null()
            enc.encode_null()
        }
        Bool => enc.encode_bool(dec.decode_bool())
        Int => enc.encode_int(dec.decode_int(8), 8)
        Float => enc.encode_float(dec.decode_float(8), 8)
        Str => transcode_str(dec, enc)
        Date => enc.encode_date(dec.decode_date())
        Time => enc.encode_time(dec.decode_time())
        DateTime => enc.encode_datetime(dec.decode_datetime())
        OffsetDateTime => enc.encode_offset_datetime(dec.decode_offset_datetime())
        Seq => transcode_seq(dec, enc)
        Map => transcode_map(dec, enc)
        End => 0
    }
}

fn transcode_str(dec: &Decoder, enc: &Encoder) usize {
    let sb = string_builder(32)
    defer sb.deinit()
    dec.decode_str(sb.writer())
    return enc.encode_str(sb.as_view())
}

fn transcode_seq(dec: &Decoder, enc: &Encoder) usize {
    enc.begin_seq(dec.begin_seq())
    while !dec.has_error() and !enc.has_error() {
        const next = dec.peek_kind()
        if next == ValueKind.End {
            break
        }
        transcode(dec, enc)
    }
    dec.end_seq()
    return enc.end_seq()
}

fn transcode_map(dec: &Decoder, enc: &Encoder) usize {
    let key = string_builder(32)
    defer key.deinit()
    enc.begin_map(dec.begin_map())
    while !dec.has_error() and !enc.has_error() {
        key.clear()
        if !dec.next_key(&key) {
            break
        }
        enc.key(key.as_view())
        transcode(dec, enc)
    }
    dec.end_map()
    return enc.end_map()
}

// =============================================================================
// ValueDecoder - a Decoder over a borrowed tree
// =============================================================================

// An open array or map and the position of its next element.
type Frame = struct {
    node: &Value
    pos: usize
}

// Reads a tree through the Decoder interface. Strings come out of `decode_str` as written; a date
// or time read as a string is written as ISO 8601, and a string read as a date or time is parsed.
// Borrows the tree: it must outlive the decoder.
pub type ValueDecoder = struct {
    root: &Value
    root_done: bool
    stack: List(Frame)
    error: ValueError?
}

pub fn value_decoder(root: &Value, allocator: &Allocator? = null) ValueDecoder {
    return .{ root = root, root_done = false, stack = list(0, allocator), error = null }
}

pub fn deinit(self: move ValueDecoder) {
    self.stack.deinit()
}

pub fn get_error(self: &ValueDecoder) ValueError? {
    return self.error
}

fn fail(self: &ValueDecoder, err: ValueError) {
    if self.error.is_none() {
        self.error = Some(err)
    }
}

// The value the next read takes, or null at the end of the enclosing container.
fn current(self: &ValueDecoder) &Value? {
    if self.error.is_some() {
        return null
    }
    if self.stack.len == 0 {
        if self.root_done {
            return null
        }
        return Some(self.root)
    }
    const top = self.stack.last().unwrap()
    return top.node.* match {
        Array(items) => items.get_ref(top.pos)
        Map(d) => {
            const e = d.entry_at(top.pos)?
            Some(&e.value)
        }
        else => null
    }
}

// Steps past the current value.
fn consume(self: &ValueDecoder) {
    if self.stack.len == 0 {
        self.root_done = true
        return
    }
    const top = self.stack.last_ref().unwrap()
    top.pos = top.pos + 1
}

// The current value, stepped past, or null (and NoValue) when there is none.
fn take(self: &ValueDecoder) &Value? {
    const v = self.current()
    if v.is_none() {
        self.fail(ValueError.NoValue)
        return null
    }
    self.consume()
    return v
}

fn mismatch(self: &ValueDecoder) {
    self.fail(ValueError.TypeMismatch)
}

pub fn peek_kind(self: &ValueDecoder) ValueKind {
    return self.current() match {
        Some(v) => v.kind()
        None => ValueKind.End
    }
}

pub fn decode_null(self: &ValueDecoder) bool {
    const v = self.current()
    if v.is_none() {
        return false
    }
    if !v.unwrap().is_null() {
        return false
    }
    self.consume()
    return true
}

pub fn decode_bool(self: &ValueDecoder) bool {
    const v = self.take()
    if v.is_none() {
        return false
    }
    const got = v.unwrap().as_bool()
    if got.is_none() {
        self.mismatch()
        return false
    }
    return got.unwrap()
}

pub fn decode_int(self: &ValueDecoder, width: u8) i64 {
    const v = self.take()
    if v.is_none() {
        return 0
    }
    const got = v.unwrap().as_i64()
    if got.is_none() {
        self.mismatch()
        return 0
    }
    return got.unwrap()
}

pub fn decode_uint(self: &ValueDecoder, width: u8) u64 {
    const n = self.decode_int(width)
    if n < 0 {
        self.mismatch()
        return 0
    }
    return n as u64
}

pub fn decode_float(self: &ValueDecoder, width: u8) f64 {
    const v = self.take()
    if v.is_none() {
        return 0.0
    }
    const got = v.unwrap().as_f64()
    if got.is_none() {
        self.mismatch()
        return 0.0
    }
    return got.unwrap()
}

pub fn decode_str(self: &ValueDecoder, w: Writer) bool {
    const v = self.take()
    if v.is_none() {
        return false
    }
    v.unwrap().* match {
        Str(s) => { w.write_str(s.view) }
        Date(d) => { d.format(w, "") }
        Time(t) => { t.format(w, "") }
        DateTime(dt) => { dt.format(w, "") }
        OffsetDateTime(odt) => { odt.format(w, "") }
        else => {
            self.mismatch()
            return false
        }
    }
    return true
}

pub fn decode_bytes(self: &ValueDecoder, w: Writer) bool {
    const v = self.take()
    if v.is_none() {
        return false
    }
    v.unwrap().* match {
        Str(s) => { w.write_str(s.view) }
        Array(items) => {
            for i in 0..items.len {
                const b = items[i].as_i64()
                if b.is_none() {
                    self.mismatch()
                    return false
                }
                w.write_byte(b.unwrap() as u8)
            }
        }
        else => {
            self.mismatch()
            return false
        }
    }
    return true
}

pub fn begin_seq(self: &ValueDecoder) usize {
    const v = self.current()
    if v.is_none() {
        self.fail(ValueError.NoValue)
        return 0
    }
    if !v.unwrap().is_array() {
        self.mismatch()
        return 0
    }
    self.stack.push(Frame { node = v.unwrap(), pos = 0 })
    return v.unwrap().len()
}

pub fn end_seq(self: &ValueDecoder) bool {
    return self.close()
}

pub fn begin_map(self: &ValueDecoder) usize {
    const v = self.current()
    if v.is_none() {
        self.fail(ValueError.NoValue)
        return 0
    }
    if !v.unwrap().is_map() {
        self.mismatch()
        return 0
    }
    self.stack.push(Frame { node = v.unwrap(), pos = 0 })
    return v.unwrap().len()
}

pub fn end_map(self: &ValueDecoder) bool {
    return self.close()
}

fn close(self: &ValueDecoder) bool {
    if self.error.is_some() or self.stack.len == 0 {
        return false
    }
    const _frame = self.stack.pop()
    self.consume()
    return true
}

pub fn next_key(self: &ValueDecoder, sb: &StringBuilder) bool {
    if self.error.is_some() or self.stack.len == 0 {
        return false
    }
    const top = self.stack.last().unwrap()
    const d = top.node.as_map()
    if d.is_none() {
        return false
    }
    const e = d.unwrap().entry_at(top.pos)
    if e.is_none() {
        return false
    }
    sb.append(e.unwrap().key.view)
    return true
}

pub fn skip_value(self: &ValueDecoder) bool {
    return self.take().is_some()
}

pub fn has_error(self: &ValueDecoder) bool {
    return self.error.is_some()
}

pub fn decode_date(self: &ValueDecoder) Date {
    const v = self.take()
    if v.is_some() {
        v.unwrap().* match {
            Date(d) => { return d }
            Str(s) => {
                const r = parse_date(s.view)
                if r.is_ok() {
                    return r.unwrap()
                }
            }
            else => {}
        }
    }
    self.mismatch()
    return date_from_epoch_day(0)
}

pub fn decode_time(self: &ValueDecoder) Time {
    const v = self.take()
    if v.is_some() {
        v.unwrap().* match {
            Time(t) => { return t }
            Str(s) => {
                const r = parse_time(s.view)
                if r.is_ok() {
                    return r.unwrap()
                }
            }
            else => {}
        }
    }
    self.mismatch()
    return Time { ticks = 0 }
}

pub fn decode_datetime(self: &ValueDecoder) DateTime {
    const v = self.take()
    if v.is_some() {
        v.unwrap().* match {
            DateTime(dt) => { return dt }
            Str(s) => {
                const r = parse_datetime(s.view)
                if r.is_ok() {
                    return r.unwrap()
                }
            }
            else => {}
        }
    }
    self.mismatch()
    return datetime_from_ticks(0)
}

pub fn decode_offset_datetime(self: &ValueDecoder) OffsetDateTime {
    const v = self.take()
    if v.is_some() {
        v.unwrap().* match {
            OffsetDateTime(odt) => { return odt }
            Str(s) => {
                const r = parse_offset_datetime(s.view)
                if r.is_ok() {
                    return r.unwrap()
                }
            }
            else => {}
        }
    }
    self.mismatch()
    return OffsetDateTime { instant = UNIX_EPOCH, offset = 0 }
}

#implement(ValueDecoder, Decoder)

// =============================================================================
// ValueEncoder - an Encoder that builds a tree
// =============================================================================

// Builds a Value from Encoder calls. `finish` hands over the tree.
pub type ValueEncoder = struct {
    // Open arrays and maps, innermost last.
    open: List(Value)
    // Keys written and not yet given a value, innermost last.
    keys: List(OwnedString)
    // `keys.len` when each open container was begun.
    key_base: List(usize)
    result: Value?
    allocator: &Allocator?
    error: ValueError?
}

pub fn value_encoder(allocator: &Allocator? = null) ValueEncoder {
    return .{
        open = list(0, allocator),
        keys = list(0, allocator),
        key_base = list(0, allocator),
        result = null,
        allocator = allocator,
        error = null,
    }
}

pub fn deinit(self: move ValueEncoder) {
    self.open.deinit()
    self.keys.deinit()
    self.key_base.deinit()
    self.result match {
        Some(v) => v.deinit()
        None => {}
    }
}

pub fn get_error(self: &ValueEncoder) ValueError? {
    return self.error
}

// Hands over the tree written so far: the one top-level value, or an error when none was written or
// a container is still open.
pub fn finish(self: &ValueEncoder) Result(Value, ValueError) {
    if self.error.is_some() {
        return Err(self.error.unwrap())
    }
    if self.open.len > 0 {
        return Err(ValueError.NoValue)
    }
    const taken = replace(&self.result, null)
    return taken match {
        Some(v) => Ok(move v)
        None => Err(ValueError.NoValue)
    }
}

fn fail(self: &ValueEncoder, err: ValueError) {
    if self.error.is_none() {
        self.error = Some(err)
    }
}

// Places a finished value: as the result, as the next array element, or under the pending key.
fn emit(self: &ValueEncoder, v: move Value) usize {
    if self.open.len == 0 {
        if self.result.is_some() {
            self.fail(ValueError.NoValue)
            v.deinit()
            return 0
        }
        self.result = Some(move v)
        return 0
    }
    const parent = self.open.last_ref().unwrap()
    if parent.is_array() {
        parent.push(v)
        return 0
    }
    if self.keys.len <= self.key_base.last().unwrap() {
        self.fail(ValueError.MissingKey)
        v.deinit()
        return 0
    }
    const k = self.keys.pop().unwrap()
    parent.set(k.view, v)
    k.deinit()
    return 0
}

pub fn encode_null(self: &ValueEncoder) usize {
    return self.emit(Value.Null)
}

// Under a pending key the entry is left out; anywhere else a Null.
pub fn encode_none(self: &ValueEncoder) usize {
    const keyed = self.open.len > 0 and self.keys.len > self.key_base.last().unwrap()
    if keyed {
        const k = self.keys.pop().unwrap()
        k.deinit()
        return 0
    }
    return self.emit(Value.Null)
}

pub fn encode_bool(self: &ValueEncoder, v: bool) usize {
    return self.emit(Value.Bool(v))
}

pub fn encode_int(self: &ValueEncoder, v: i64, width: u8) usize {
    return self.emit(Value.Int(v))
}

pub fn encode_uint(self: &ValueEncoder, v: u64, width: u8) usize {
    return self.emit(Value.Int(v as i64))
}

pub fn encode_float(self: &ValueEncoder, v: f64, width: u8) usize {
    return self.emit(Value.Float(v))
}

pub fn encode_str(self: &ValueEncoder, v: String) usize {
    return self.emit(value_str(v, self.allocator))
}

pub fn encode_bytes(self: &ValueEncoder, v: u8[]) usize {
    let items = value_array(self.allocator)
    for b in v {
        items.push(Value.Int(b as i64))
    }
    return self.emit(items)
}

pub fn encode_date(self: &ValueEncoder, v: Date) usize {
    return self.emit(Value.Date(v))
}

pub fn encode_time(self: &ValueEncoder, v: Time) usize {
    return self.emit(Value.Time(v))
}

pub fn encode_datetime(self: &ValueEncoder, v: DateTime) usize {
    return self.emit(Value.DateTime(v))
}

pub fn encode_offset_datetime(self: &ValueEncoder, v: OffsetDateTime) usize {
    return self.emit(Value.OffsetDateTime(v))
}

pub fn begin_seq(self: &ValueEncoder, len: usize) usize {
    self.open.push(value_array(self.allocator))
    self.key_base.push(self.keys.len)
    return 0
}

pub fn end_seq(self: &ValueEncoder) usize {
    return self.close()
}

pub fn begin_map(self: &ValueEncoder, len: usize) usize {
    self.open.push(value_map(self.allocator))
    self.key_base.push(self.keys.len)
    return 0
}

pub fn end_map(self: &ValueEncoder) usize {
    return self.close()
}

fn close(self: &ValueEncoder) usize {
    if self.open.len == 0 {
        self.fail(ValueError.NoValue)
        return 0
    }
    const _base = self.key_base.pop()
    return self.emit(self.open.pop().unwrap())
}

pub fn key(self: &ValueEncoder, name: String) usize {
    self.keys.push(from_view(name, self.allocator))
    return 0
}

pub fn is_human_readable(self: &ValueEncoder) bool {
    return true
}

pub fn has_error(self: &ValueEncoder) bool {
    return self.error.is_some()
}

#implement(ValueEncoder, Encoder)

// =============================================================================
// Tests
// =============================================================================

test "map entries keep insertion order and set replaces in place" {
    let m = value_map()
    defer m.deinit()
    m.set("z", Value.Int(1))
    m.set("a", value_str("x"))
    m.set("z", Value.Int(2))
    assert_eq(m.len(), 2 as usize, "two keys")
    assert_true(m.as_map().unwrap().entry_at(0).unwrap().key.view == "z", "first key stays first")
    assert_eq(m.get("z").unwrap().as_i64().unwrap(), 2i64, "value replaced")
    assert_eq(m.get("a").unwrap().as_string().unwrap(), "x", "string value")
    assert_true(m.get("missing").is_none(), "absent key")
}

test "an encoder builds a tree a decoder reads back" {
    let enc = value_encoder()
    defer enc.deinit()
    const e = enc.encoder()
    e.begin_map(3)
    e.key("n")
    e.encode_int(7, 8)
    e.key("list")
    e.begin_seq(2)
    e.encode_bool(true)
    e.encode_date(date(2026, Month.October, 14).unwrap())
    e.end_seq()
    e.key("s")
    e.encode_str("hi")
    e.end_map()
    let tree = enc.finish().unwrap()
    defer tree.deinit()

    assert_eq(tree.get("n").unwrap().as_i64().unwrap(), 7i64, "int")
    assert_eq(tree.get("list").unwrap().len(), 2 as usize, "array")
    assert_true(tree.get("list").unwrap().at(1).unwrap().as_date().is_some(), "date kept")

    let dec = value_decoder(&tree)
    defer dec.deinit()
    let copy = read_value(&dec.decoder())
    defer copy.deinit()
    assert_true(!dec.has_error(), "no error")
    assert_eq(copy.get("s").unwrap().as_string().unwrap(), "hi", "string round-trips")
    assert_true(copy.as_map().unwrap().entry_at(1).unwrap().key.view == "list", "order kept")
}

test "a decoder reports a kind mismatch" {
    const v = Value.Bool(true)
    let dec = value_decoder(&v)
    defer dec.deinit()
    const d = dec.decoder()
    const _n = d.decode_int(8)
    assert_true(d.has_error(), "bool read as int")
    assert_true(dec.get_error().unwrap() == ValueError.TypeMismatch, "mismatch")
}

test "an encoder refuses a map value without a key" {
    let enc = value_encoder()
    defer enc.deinit()
    const e = enc.encoder()
    e.begin_map(1)
    e.encode_int(1, 8)
    e.end_map()
    assert_true(e.has_error(), "error channel set")
    const r = enc.finish()
    assert_true(r.is_err(), "no tree")
}
