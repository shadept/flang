//! TEST: memory_field_moves_elements
//! EXIT: 7

// A type that keeps its storage in a `Memory` field takes non-copyable elements out of it, as an
// `owned` field allows (RFC-043).

import std.allocator
import std.option

type FileHandle = struct {
    owned fd: i32
}

fn close(h: move FileHandle) i32 {
    const fd = h.fd
    leak(h)
    return fd
}

type Slots = struct {
    mem: Memory
}

pub fn main() i32 {
    const a = context.allocator
    let s = Slots { mem = a.alloc(2 * size_of(FileHandle), align_of(FileHandle)).unwrap() }
    let at0: &FileHandle = s.mem.ptr as &FileHandle
    at0.* = FileHandle { fd = 3 }
    let at1: &FileHandle = (s.mem.ptr as &FileHandle) + 1usize
    at1.* = FileHandle { fd = 4 }
    const first = move (s.mem.ptr as &FileHandle).*
    const second = move ((s.mem.ptr as &FileHandle) + 1usize).*
    a.dealloc(s.mem)
    return close(first) + close(second)
}
