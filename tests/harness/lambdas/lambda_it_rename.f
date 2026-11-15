//! TEST: lambda_it_rename
//! EXIT: 42

// RFC-045: `#it(name)` on a parameter names the parameter of an arrow-less lambda that fills it.
// `it` stays unbound there, so an outer `it` stays visible and an inner arrow-less lambda's `it`
// shadows nothing.

type Acc = struct {
    total: i32
}

fn with_acc(#it(acc) body: fn(&Acc)) i32 {
    let a = Acc { total = 0 }
    body(&a)
    return a.total
}

fn add(self: &Acc, n: i32) {
    self.total = self.total + n
}

fn each(n: i32, f: fn(i32)) {
    for i in 0..n {
        f(i)
    }
}

fn bounded(x: i32, #it(v) f: $F) i32 where F: fn(i32) i32 {
    return f(x)
}

fn first(self: i32, #it(n) f: fn(i32) i32, extra: i32 = 0) i32 {
    return f(self) + extra
}

pub fn main() i32 {
    const it: i32 = 1
    const a: i32 = with_acc {
        acc.add(it)
        each(3) { acc.add(it) }
    }
    const b: i32 = bounded(4) { v * 2 }
    const c: i32 = bounded(x = 5, f = { v + it })
    const seven: i32 = 7
    const d: i32 = seven.first { n * 2 }
    const e: i32 = bounded(6) { x => x - 6 }
    return a + b + c + d + e + 10
}
