// Minimal I/O utilities for early testing
// NOTE: Stopgap until std/io/fmt.f lands (Milestone 19)

import core.string

#foreign fn puts(ptr: &u8) i32
#foreign fn printf(fmt: &u8) i32
#foreign fn putchar(ch: i32) i32

// Prints without a trailing newline.
// WARNING: Temporary implementation calls C printf with the string as the
//          format argument. This will interpret '%' sequences. See known-issues.
pub fn print(s: String) i32 {
    return printf(s.ptr)
}

// Prints with a trailing newline.
pub fn println(s: String) i32 {
    // Use puts so we avoid formatting behavior and always append '\n'
    return puts(s.ptr)
}
