// Minimal I/O utilities for early testing
// NOTE: Stopgap until std/io/fmt.f lands (Milestone 19)

import core.string

#foreign fn printf(fmt: &u8, val: u8) i32
#foreign fn printf(fmt: &u8, val: i32) i32
#foreign fn printf(fmt: &u8, len: i32, ptr: &u8) i32

// Length-aware printing using C stdio printf via varargs.
// We avoid passing user strings as format strings to eliminate format injection.
// Note: Embedded NUL bytes will truncate due to %s semantics; will be addressed in M19.

pub fn print(value: i32) i32 {
    return printf("%d".ptr, value)
}

pub fn print(value: String) i32 {
    // printf("%.*s", (int)len, ptr)
    return printf("%.*s".ptr, value.len as i32, value.ptr)
}

pub fn println(value: u8) i32 {
    return printf("%c\n".ptr, value)
}

pub fn println(value: i32) i32 {
    return printf("%d\n".ptr, value)
}

pub fn println(value: isize) i32 {
    return printf("%lld\n".ptr, value)
}

pub fn println(value: usize) i32 {
    return printf("%ulld\n".ptr, value)
}

pub fn println(value: String) i32 {
    // printf("%.*s\n", (int)len, ptr)
    return printf("%.*s\n".ptr, value.len as i32, value.ptr)
}


pub fn println(value: Option($T)) i32 {
    if (value.has_value) {
        return println(value.value)
    }
    return println("null")
}
