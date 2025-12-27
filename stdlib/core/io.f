// Minimal I/O utilities for early testing
// NOTE: Stopgap until std/io/fmt.f lands (Milestone 19)

import core.string

#foreign fn printf(fmt: &u8, len: i32, ptr: &u8) i32
 
 // Length-aware printing using C stdio printf via varargs.
 // We avoid passing user strings as format strings to eliminate format injection.
 // Note: Embedded NUL bytes will truncate due to %s semantics; will be addressed in M19.
 
 pub fn print(s: String) i32 {
     // printf("%.*s", (int)len, ptr)
     return printf("%.*s".ptr, s.len as i32, s.ptr)
 }
 
 pub fn println(s: String) i32 {
     // printf("%.*s\n", (int)len, ptr)
     return printf("%.*s\n".ptr, s.len as i32, s.ptr)
 }
 
 