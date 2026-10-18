//! TEST: lambda_trailing
//! EXIT: 42

// RFC-039: a lambda after the call's `)` or name fills its last callable parameter, through a name,
// a call, a method, a chain and a callable field.

type Counter = struct {
    on_tick: fn(i32) i32
}

fn run(f: fn() i32) i32 {
    return f()
}

fn twice(x: i32, f: $F) i32 where F: fn(i32) i32 {
    return f(f(x))
}

fn add(self: i32, f: fn(i32) i32) i32 {
    return f(self)
}

pub fn main() i32 {
    const bias: i32 = 1
    const a: i32 = run { 2 }
    const b: i32 = twice(3) { x: i32 => x + bias }
    const c: i32 = 10
        .add { x: i32 => x * 2 }
        .add { x: i32 => x - 5 }
    const k = Counter { on_tick = { x: i32 => x + 2 } }
    const d: i32 = k.on_tick(0)
    const e: i32 = twice(1) { x: i32 =>
        const y: i32 = x * 2
        y
    }
    return a + b + c + d + e + 14
}
