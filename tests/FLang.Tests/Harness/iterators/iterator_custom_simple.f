//! TEST: iterator_custom_simple
//! EXIT: 15

// Simple custom iterator that counts down
struct Countdown {
    from: i32
}

fn iter(c: &Countdown) Countdown {
    return .{ from = c.from }
}

fn next(c: &Countdown) i32? {
    if (c.from <= 0) {
        return null
    }
    let val = c.from
    c.from = c.from - 1
    return val
}

pub fn main() i32 {
    let cd: Countdown = .{ from = 5 }
    let sum: i32 = 0
    for (x in cd) {
        sum = sum + x
    }
    return sum  // 5 + 4 + 3 + 2 + 1 = 15
}
