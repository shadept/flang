//! TEST: labeled_coalesce
//! EXIT: 0

// The right side of `??` can leave a labeled loop.
fn half(x: i32) i32? {
    if x % 2 == 0 {
        return Some(x / 2)
    }
    return null
}

pub fn main() i32 {
    let total: i32 = 0
    let visits: i32 = 0
    outer: for i in 0..4 as i32 {
        for j in 0..4 as i32 {
            const v: i32 = half(i + j) ?? continue outer
            total = total + v
            visits = visits + 1
        }
    }
    if total != 1 or visits != 2 {
        return 1
    }
    let k: i32 = 0
    drain: loop {
        while k < 100 {
            const v: i32 = half(k) ?? break drain
            k = k + 1 + v * 0
        }
    }
    if k != 1 {
        return 2
    }
    return 0
}
