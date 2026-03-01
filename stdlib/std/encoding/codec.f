// Format-agnostic serialization interfaces.
//
// Encoder and Decoder are vtable interfaces. Each format (JSON, binary,
// MessagePack, etc.) implements them via #implement.
//
// The vtable has one method per semantic category. A width hint
// preserves the original type size so binary formats can write the
// correct number of bytes; text formats ignore it.
//
// Free functions widen narrower types and delegate to the vtable
// method with the correct width.
//
// Error types and policy (strict/lenient, naming conventions, unknown
// field handling) are defined by each format, not here.
//
// Usage:
//   #derive(MyStruct, serialize, deserialize)
//   let enc = json_encoder(&sb)
//   point.serialize(&enc.encoder())

import std.interface
import std.io.writer
import std.string_builder

// =============================================================================
// Encoder
// =============================================================================

#interface(Encoder, struct {
    encode_null:        fn() usize
    encode_bool:        fn(v: bool) usize
    encode_int:         fn(v: i64, width: u8) usize
    encode_uint:        fn(v: u64, width: u8) usize
    encode_float:       fn(v: f64, width: u8) usize
    encode_str:         fn(v: String) usize
    encode_bytes:       fn(v: u8[]) usize
    begin_seq:          fn(len: usize) usize
    end_seq:            fn() usize
    begin_map:          fn(len: usize) usize
    end_map:            fn() usize
    key:                fn(name: String) usize
    is_human_readable:  fn() bool
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
// Decoder
// =============================================================================

#interface(Decoder, struct {
    decode_null:        fn() bool
    decode_bool:        fn() bool
    decode_int:         fn(width: u8) i64
    decode_uint:        fn(width: u8) u64
    decode_float:       fn(width: u8) f64
    decode_str:         fn(w: Writer) bool
    decode_bytes:       fn(w: Writer) bool
    begin_seq:          fn() usize
    end_seq:            fn() bool
    begin_map:          fn() usize
    end_map:            fn() bool
    next_key:           fn(sb: &StringBuilder) bool
    skip_value:         fn() bool
    has_error:          fn() bool
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
