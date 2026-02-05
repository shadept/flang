// Minimal I/O utilities for early testing
// NOTE: Stopgap until std/io/fmt.f lands (Milestone 19)

import core.string

#foreign fn printf(fmt: &u8) i32
#foreign fn printf(fmt: &u8, val: u8) i32
#foreign fn printf(fmt: &u8, val1: u8, val2: u8) i32
#foreign fn printf(fmt: &u8, val1: u8, val2: u8, val3: u8) i32
#foreign fn printf(fmt: &u8, val1: u8, val2: u8, val3: u8, val4: u8) i32
#foreign fn printf(fmt: &u8, val: u8) i32
#foreign fn printf(fmt: &u8, val: i32) i32
#foreign fn printf(fmt: &u8, val: u32) i32
#foreign fn printf(fmt: &u8, val: i64) i32
#foreign fn printf(fmt: &u8, val: u64) i32
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

pub fn println(value: u32) i32 {
    return printf("%ud\n".ptr, value)
}

pub fn println(value: char) i32 {
    let buf = [0u8; 4]
    const len = encode_char(value, buf)
    // TODO gap no interge patterns
    // return len match {
    //     1 => printf("%c\n".ptr, buf[0]),
    //     2 => printf("%c%c\n".ptr, buf[0], buf[1]),
    //     3 => printf("%c%c%c\n".ptr, buf[0], buf[1], buf[2]),
    //     4 => printf("%c%c%c%c\n".ptr, buf[0], buf[1], buf[2], buf[3]),
    //     _ => printf("invalid utf8\n".ptr)
    // }
    return if (len == 1) {
        printf("%c\n".ptr, buf[0])
    } else if (len == 2) {
        printf("%c%c\n".ptr, buf[0], buf[1])
    } else if (len == 3) {
        printf("%c%c%c\n".ptr, buf[0], buf[1], buf[2])
    } else if (len == 4) {
        printf("%c%c%c%c\n".ptr, buf[0], buf[1], buf[2], buf[3])
    } else {
        printf("invalid utf8\n".ptr)
    }
}

pub fn println(value: isize) i32 {
    return printf("%lld\n".ptr, value as i64)
}

pub fn println(value: usize) i32 {
    return printf("%llu\n".ptr, value as u64)
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
