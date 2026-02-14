// Extended print/println overloads for types requiring std imports
// Primitive overloads (i32, u8, u32, isize, usize, String) remain in core/io.f

import std.encoding.utf8
import std.io.file
import std.string

pub fn print(value: OwnedString) i32 {
    return print(value.as_view())
}

pub fn println(value: OwnedString) i32 {
    return println(value.as_view())
}

pub fn println(value: char) i32 {
    let buf = [0u8; 4]
    const len = encode_char(value, buf)
    return if len == 1 {
        printf("%c\n".ptr, buf[0])
    } else if len == 2 {
        printf("%c%c\n".ptr, buf[0], buf[1])
    } else if len == 3 {
        printf("%c%c%c\n".ptr, buf[0], buf[1], buf[2])
    } else if len == 4 {
        printf("%c%c%c%c\n".ptr, buf[0], buf[1], buf[2], buf[3])
    } else {
        panic("invalid utf-8")
        0
    }
}

pub fn println(value: Option($T)) i32 {
    if value.has_value {
        return println(value.value)
    }
    return println("null")
}
