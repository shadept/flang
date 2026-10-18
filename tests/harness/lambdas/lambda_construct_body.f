//! TEST: lambda_construct_body
//! EXIT: 42

// RFC-039: a trailing arrow-less lambda whose body is a construction, unspaced: named
// (`Handler{...}`) and anonymous (`.{...}`) against an expected type, with `it` in a field and the
// lambda's return type a type parameter the construction pins. Nested arrow-less lambdas each
// bind their own `it`; a trailing lambda in an `if` header is parenthesized and chains on.

type Handler = struct {
    fd: u32
}

fn make(val: u32, f: fn(u32) $T) T {
    return f(val)
}

pub fn main() i32 {
    const a: Handler = make(5){Handler{fd=it}}
    let h: Handler = make(7){.{fd=it}}
    const b: Handler = make(10u32) { x: u32 => Handler { fd = x * 3 } }
    const c: Handler = make(1){Handler{fd=make(it){it+1}}}
    if (make(3){Handler{fd=it}}.fd == 3) {
        return (a.fd + h.fd + b.fd + c.fd - 2) as i32
    }
    return 0
}
