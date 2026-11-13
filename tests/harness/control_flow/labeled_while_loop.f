//! TEST: labeled_while_loop
//! EXIT: 0

// A labeled `while` is restarted from an inner `while`; a labeled `loop` is left from one.
fn first_pair(target: i32, limit: i32) i32 {
    let a: i32 = 0
    outer: while a < limit {
        a = a + 1
        let b: i32 = a
        while b < limit {
            b = b + 1
            if a * b == target {
                return a * 10 + b
            }
            if a * b > target {
                continue outer
            }
        }
    }
    return -1
}

fn count_until(stop: i32) i32 {
    let n: i32 = 0
    scan: loop {
        let k: i32 = 0
        while k < 10 {
            k = k + 1
            n = n + 1
            if n == stop {
                break scan
            }
        }
    }
    return n
}

pub fn main() i32 {
    if first_pair(15, 10) != 35 {
        return 1
    }
    if count_until(25) != 25 {
        return 2
    }
    return 0
}
