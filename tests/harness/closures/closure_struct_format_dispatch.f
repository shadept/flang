//! TEST: closure_struct_format_dispatch
//! EXIT: 0
//! STDOUT: a42b
//! STDOUT: a42b

// A closure held in a generic struct field, reached through the `format`
// convention: the generic `append` finds `format`, which calls the field.
// This is the shape a deferred formatting value takes.

import std.string_builder
import std.io.writer
import std.string
import core.io

type Deferred = struct(F) {
    emit: F,
}

fn deferred(f: $F) Deferred(F) {
    return .{ emit = f }
}

pub fn format(self: &Deferred($F), w: Writer, spec: String) {
    self.emit(w)
}

pub fn main() i32 {
    let x = 42i32
    let d = deferred(fn(w: Writer) {
        w.write_str("a")
        x.format(w, "")
        w.write_str("b")
    })

    let out = string_builder(16)
    defer out.deinit()
    out.append(d)
    println(out.as_view())

    println(d)
    return 0
}
