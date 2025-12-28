// Core list abstraction backed by manually managed heap storage. This file
// only declares the canonical layout for List(T) and provides placeholder
// operations that panic via __flang_unimplemented until the allocator-backed
// implementation lands.

import core.runtime

pub struct List(T) {
    ptr: &T
    len: usize
    cap: usize
}

pub fn list_new() List($T) {
    let zero: usize = 0
    return .{ ptr = zero as &T, len = 0, cap = 0 }
}

pub fn list_push(list: &List($T), value: T) {
    __flang_unimplemented()
}

pub fn list_pop(list: &List($T)) T? {
    __flang_unimplemented()
    return null
}

pub fn list_get(list: &List($T), index: usize) T {
    __flang_unimplemented()
    let zero: usize = 0
    return zero as T
}
