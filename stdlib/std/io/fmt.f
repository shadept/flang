import std.string

pub fn print(value: OwnedString) i32 {
    return print(value.as_view())
}

pub fn println(value: OwnedString) i32 {
    return println(value.as_view())
}
