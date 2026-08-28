//! TEST: global_const_static_init_refs
//! EXIT: 42

import std.string

// The initializer forms whose value is an address the linker supplies, or a tag rather than a
// value: a qualified enum variant, an unqualified one, the address of another const, and a
// pointer-to-pointer cast of that address. Each becomes bytes plus a relocation in the const's
// global, so none of these needs an init function.

type Mode = enum {
    Read
    Write
    Append
}

type Handle = struct {
    fd: i32
}

type Ops = struct {
    twice: fn(i32) i32
}

type Stream = struct {
    mode: Mode
    handle: Handle
    ops: &Ops
    raw: &u8
    label: String
}

fn double(x: i32) i32 {
    return x + x
}

const BACKING: Handle = Handle { fd = 7 }
const OPS = Ops { twice = double }

const BARE: Mode = Read

const STREAM = Stream {
    mode = Mode.Append,
    handle = Handle { fd = 3 },
    ops = &OPS,
    raw = &BACKING as &u8,
    label = "hi",
}

pub fn main() i32 {
    // A qualified variant is its tag; `Append` is declared third.
    if STREAM.mode != Mode.Append {
        return 1
    }
    if BARE != Mode.Read {
        return 2
    }
    if STREAM.handle.fd != 3 {
        return 3
    }
    // The relocation resolved to the const it named, not to some other global.
    if STREAM.ops.twice(21) != 42 {
        return 4
    }
    let back = STREAM.raw as &Handle
    if back.fd != 7 {
        return 5
    }
    if STREAM.label != "hi" {
        return 6
    }
    return 42
}
