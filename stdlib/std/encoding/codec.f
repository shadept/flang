// Format-agnostic serialization interfaces.
//
// Encoder and Decoder are vtable interfaces. Each format (JSON, binary, MessagePack, etc.)
// implements them via #implement.
//
// The vtable has one method per semantic category. A width hint preserves the original type size so
// binary formats can write the correct number of bytes; text formats ignore it.
//
// Free functions widen narrower types and delegate to the vtable method with the correct width.
//
// Error types and policy (strict/lenient, naming conventions, unknown field handling) are defined
// by each format, not here. Both sides report failure through `has_error`; each format's own
// `get_error` says which. `KeyCase` is the shared vocabulary a format's naming option uses.
//
// `encode_none` is an absent value, what `Option`'s `serialize` writes for `None`: a format that
// can leave a map entry out drops the key before it, and writes null anywhere else. A map's length
// hint is therefore an upper bound.
//
// Dates and times have their own methods. A format without them (JSON, CSV) writes ISO 8601 / RFC
// 3339 text and reads it back; `DateParsing` decides whether such a format's decoder reports a
// string that reads as one as a date or time in `peek_kind`.
//
// Usage:
//   #derive(MyStruct, serialize, deserialize)
//   let enc = json_encoder(&sb)
//   point.serialize(&enc.encoder())

import std.collections.list
import std.interface
import std.io.writer
import std.option
import std.result
import std.string
import std.string_builder
import std.time

// =============================================================================
// Kinds
// =============================================================================

// What a self-describing decoder holds next (`peek_kind`). `End` is the close of the enclosing
// sequence, the end of the input, or an error.
pub type ValueKind = enum {
    Null
    Bool
    Int
    Float
    Str
    Date
    Time
    DateTime
    OffsetDateTime
    Seq
    Map
    End
}

// Which strings a text format without dates of its own reads as dates and times.
pub type DateParsing = enum {
    // Strings stay strings.
    Off
    // Every string that reads as ISO 8601 / RFC 3339.
    All
    // Only values under these keys (CSV: columns), by the innermost key above the value.
    Keys(String[])
}

// Whether a value under `key` is read for dates. `key` is null outside any map.
pub fn applies(self: DateParsing, key: String?) bool {
    return self match {
        Off => false
        All => true
        Keys(names) => {
            if key.is_none() {
                return false
            }
            for name in names {
                if name == key.unwrap() {
                    return true
                }
            }
            false
        }
    }
}

// The date or time kind `s` reads as in ISO 8601 / RFC 3339, or `Str`. A date alone is a `Date`, a
// time alone a `Time`, a date and time with an offset an `OffsetDateTime`, without one a
// `DateTime`.
pub fn temporal_kind(s: String) ValueKind {
    if parse_date(s).is_ok() {
        return ValueKind.Date
    }
    if parse_time(s).is_ok() {
        return ValueKind.Time
    }
    if parse_offset_datetime(s).is_ok() {
        return ValueKind.OffsetDateTime
    }
    if parse_datetime(s).is_ok() {
        return ValueKind.DateTime
    }
    return ValueKind.Str
}

// How a format spells map keys. Struct fields are snake_case; `Camel` writes `start_line` as
// `startLine` and reads `startLine` back as `start_line`. A key with no `_` (or no capital, read
// back) is the same under both.
pub type KeyCase = enum {
    Verbatim
    Camel
}

// =============================================================================
// Encoder
// =============================================================================

#interface(Encoder, struct {
    encode_null: fn() usize
    encode_none: fn() usize
    encode_bool: fn(v: bool) usize
    encode_int: fn(v: i64, width: u8) usize
    encode_uint: fn(v: u64, width: u8) usize
    encode_float: fn(v: f64, width: u8) usize
    encode_str: fn(v: String) usize
    encode_bytes: fn(v: u8[]) usize
    begin_seq: fn(len: usize) usize
    end_seq: fn() usize
    begin_map: fn(len: usize) usize
    end_map: fn() usize
    key: fn(name: String) usize
    is_human_readable: fn() bool
    encode_date: fn(v: Date) usize
    encode_time: fn(v: Time) usize
    encode_datetime: fn(v: DateTime) usize
    encode_offset_datetime: fn(v: OffsetDateTime) usize
    has_error: fn() bool
})

pub fn encode_i8(enc: &Encoder, v: i8) usize { return enc.encode_int(v as i64, 1) }
pub fn encode_i16(enc: &Encoder, v: i16) usize { return enc.encode_int(v as i64, 2) }
pub fn encode_i32(enc: &Encoder, v: i32) usize { return enc.encode_int(v as i64, 4) }
pub fn encode_i64(enc: &Encoder, v: i64) usize { return enc.encode_int(v, 8) }
pub fn encode_isize(enc: &Encoder, v: isize) usize { return enc.encode_int(v as i64, 8) }

pub fn encode_u8(enc: &Encoder, v: u8) usize { return enc.encode_uint(v as u64, 1) }
pub fn encode_u16(enc: &Encoder, v: u16) usize { return enc.encode_uint(v as u64, 2) }
pub fn encode_u32(enc: &Encoder, v: u32) usize { return enc.encode_uint(v as u64, 4) }
pub fn encode_u64(enc: &Encoder, v: u64) usize { return enc.encode_uint(v, 8) }
pub fn encode_usize(enc: &Encoder, v: usize) usize { return enc.encode_uint(v as u64, 8) }

pub fn encode_f32(enc: &Encoder, v: f32) usize { return enc.encode_float(v as f64, 4) }
pub fn encode_f64(enc: &Encoder, v: f64) usize { return enc.encode_float(v, 8) }

// =============================================================================
// Serialize
// =============================================================================

// A type that writes itself to an Encoder. `#derive(T, serialize)` implements it for a struct.
pub type Serialize = contract {
    fn serialize(self: &Self, enc: &Encoder)
}

pub fn serialize(self: &bool, enc: &Encoder) { enc.encode_bool(self.*) }
pub fn serialize(self: &i8, enc: &Encoder) { encode_i8(enc, self.*) }
pub fn serialize(self: &i16, enc: &Encoder) { encode_i16(enc, self.*) }
pub fn serialize(self: &i32, enc: &Encoder) { encode_i32(enc, self.*) }
pub fn serialize(self: &i64, enc: &Encoder) { encode_i64(enc, self.*) }
pub fn serialize(self: &isize, enc: &Encoder) { encode_isize(enc, self.*) }
pub fn serialize(self: &u8, enc: &Encoder) { encode_u8(enc, self.*) }
pub fn serialize(self: &u16, enc: &Encoder) { encode_u16(enc, self.*) }
pub fn serialize(self: &u32, enc: &Encoder) { encode_u32(enc, self.*) }
pub fn serialize(self: &u64, enc: &Encoder) { encode_u64(enc, self.*) }
pub fn serialize(self: &usize, enc: &Encoder) { encode_usize(enc, self.*) }
pub fn serialize(self: &f32, enc: &Encoder) { encode_f32(enc, self.*) }
pub fn serialize(self: &f64, enc: &Encoder) { encode_f64(enc, self.*) }
pub fn serialize(self: &String, enc: &Encoder) { enc.encode_str(self.*) }
pub fn serialize(self: &OwnedString, enc: &Encoder) { enc.encode_str(self.view) }

// `None` is an absent value (`encode_none`), `Some` its payload.
pub fn serialize(self: &Option($T), enc: &Encoder) where T: Serialize {
    if self.is_none() {
        enc.encode_none()
        return
    }
    self.unwrap_ref().serialize(enc)
}

pub fn serialize(self: &$T[], enc: &Encoder) where T: Serialize {
    enc.begin_seq(self.len)
    for &x in self.* {
        x.serialize(enc)
    }
    enc.end_seq()
}

pub fn serialize(self: &List($T), enc: &Encoder) where T: Serialize {
    enc.begin_seq(self.len)
    for &x in self {
        x.serialize(enc)
    }
    enc.end_seq()
}

// =============================================================================
// Decoder
// =============================================================================

#interface(Decoder, struct {
    decode_null: fn() bool
    decode_bool: fn() bool
    decode_int: fn(width: u8) i64
    decode_uint: fn(width: u8) u64
    decode_float: fn(width: u8) f64
    decode_str: fn(w: Writer) bool
    decode_bytes: fn(w: Writer) bool
    begin_seq: fn() usize
    end_seq: fn() bool
    begin_map: fn() usize
    end_map: fn() bool
    next_key: fn(sb: &StringBuilder) bool
    skip_value: fn() bool
    has_error: fn() bool
    peek_kind: fn() ValueKind
    decode_date: fn() Date
    decode_time: fn() Time
    decode_datetime: fn() DateTime
    decode_offset_datetime: fn() OffsetDateTime
})

pub fn decode_i8(dec: &Decoder) i8 { return dec.decode_int(1) as i8 }
pub fn decode_i16(dec: &Decoder) i16 { return dec.decode_int(2) as i16 }
pub fn decode_i32(dec: &Decoder) i32 { return dec.decode_int(4) as i32 }
pub fn decode_i64(dec: &Decoder) i64 { return dec.decode_int(8) }
pub fn decode_isize(dec: &Decoder) isize { return dec.decode_int(8) as isize }

pub fn decode_u8(dec: &Decoder) u8 { return dec.decode_uint(1) as u8 }
pub fn decode_u16(dec: &Decoder) u16 { return dec.decode_uint(2) as u16 }
pub fn decode_u32(dec: &Decoder) u32 { return dec.decode_uint(4) as u32 }
pub fn decode_u64(dec: &Decoder) u64 { return dec.decode_uint(8) }
pub fn decode_usize(dec: &Decoder) usize { return dec.decode_uint(8) as usize }

pub fn decode_f32(dec: &Decoder) f32 { return dec.decode_float(4) as f32 }
pub fn decode_f64(dec: &Decoder) f64 { return dec.decode_float(8) }
