// Core I/O primitives — printf wrappers for primitive types
// Extended overloads (char, Option, OwnedString) live in std/io/fmt.f

import core.string

#foreign fn printf(fmt: &u8) i32
#foreign fn printf(fmt: &u8, val: u8) i32
#foreign fn printf(fmt: &u8, val1: u8, val2: u8) i32
#foreign fn printf(fmt: &u8, val1: u8, val2: u8, val3: u8) i32
#foreign fn printf(fmt: &u8, val1: u8, val2: u8, val3: u8, val4: u8) i32
#foreign fn printf(fmt: &u8, val: i32) i32
#foreign fn printf(fmt: &u8, val: u32) i32
#foreign fn printf(fmt: &u8, val: i64) i32
#foreign fn printf(fmt: &u8, val: u64) i32
#foreign fn printf(fmt: &u8, len: i32, ptr: &u8) i32

pub fn print(value: i32) i32 {
    return printf("%d".ptr, value)
}

pub fn print(value: String) i32 {
    return printf("%.*s".ptr, value.len as i32, value.ptr)
}

pub fn println(value: u8) i32 {
    return printf("%c\n".ptr, value)
}

pub fn println(value: i32) i32 {
    return printf("%d\n".ptr, value)
}

pub fn println(value: u32) i32 {
    return printf("%ud\n".ptr, value)
}

pub fn println(value: isize) i32 {
    return printf("%lld\n".ptr, value as i64)
}

pub fn println(value: usize) i32 {
    return printf("%llu\n".ptr, value as u64)
}

pub fn println(value: String) i32 {
    return printf("%.*s\n".ptr, value.len as i32, value.ptr)
}
