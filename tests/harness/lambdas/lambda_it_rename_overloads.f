//! TEST: lambda_it_rename_overloads
//! EXIT: 42

// RFC-045: when the overload is still open as the lambda is checked, the overloads in play name its
// parameter; here both take `#it(acc)`, as `concurrent`'s two forms take `#it(scope)`.

type Acc = struct {
    total: i32
}

fn add(self: &Acc, n: i32) {
    self.total = self.total + n
}

fn tally(#it(acc) body: fn(&Acc) $R) R {
    let a = Acc { total = 40 }
    return body(&a)
}

fn tally(start: i32, #it(acc) body: fn(&Acc) $R) R {
    let a = Acc { total = start }
    return body(&a)
}

pub fn main() i32 {
    const n = tally {
        acc.add(2)
        acc.total
    }
    return n
}
