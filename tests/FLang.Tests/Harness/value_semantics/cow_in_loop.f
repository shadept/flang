//! TEST: cow_in_loop
//! EXIT: 0

// Copy-on-write must work correctly when mutation happens inside a loop.
// The shadow copy is created once, then subsequent iterations use it.

type Accum = struct {
    total: i32,
    count: i32
}

fn accumulate(a: Accum, n: i32) Accum {
    for i in 0..n {
        a.total = a.total + i   // first iteration triggers COW, rest use shadow
        a.count = a.count + 1
    }
    a
}

pub fn main() i32 {
    let start = Accum { total = 100, count = 0 }
    let result = accumulate(start, 5)   // adds 0+1+2+3+4 = 10

    // Original unchanged
    if start.total != 100 { return 1 }
    if start.count != 0 { return 2 }

    // Result reflects loop mutations
    if result.total != 110 { return 3 }
    if result.count != 5 { return 4 }

    return 0
}
