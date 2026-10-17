//! TEST: derive_deserialize_nested
//! EXIT: 0

// A derived `deserialize` beside std.encoding.value's: the binding's type picks it, and a nested
// struct field picks its own through the field it is assigned to.

import std.derive
import std.encoding.codec
import std.encoding.json
import std.encoding.value
import std.io.reader
import std.string_builder
import std.string_reader

type Inner = struct {
    start_line: u32
}

#derive(Inner, deserialize)

type Outer = struct {
    at: Inner
    count: i32
}

#derive(Outer, deserialize)

pub fn main() i32 {
    let mr = mem_reader("{\"count\": 2, \"at\": {\"startLine\": 9}}")
    let dec = json_decoder(mr.reader(), json_options(KeyCase.Camel))
    defer dec.deinit()
    const got: Outer = deserialize(&dec.decoder())
    if got.count != 2i32 {
        return 1
    }
    if got.at.start_line != 9u32 {
        return 2
    }
    return 0
}
