//! TEST: coalesce_diverging_rhs
//! EXPECT: 42
//! EXPECT: -1
//! EXPECT: 8
//! EXPECT: 3
//! EXPECT: done

// The right side of `??` is a match-arm body: `return`, `break` and `continue` leave from it.

import std.io.print
import std.option

fn plus_one(o: i32?) i32 {
    let v: i32 = o ?? return -1
    return v + 1
}

fn sum_present(xs: Option(i32)[]) i32 {
    let total: i32 = 0
    for o in xs {
        let v: i32 = o ?? continue
        total = total + v
    }
    return total
}

fn count_until_missing(xs: Option(i32)[]) i32 {
    let n: i32 = 0
    for o in xs {
        let _v: i32 = o ?? break
        n = n + 1
    }
    return n
}

fn note(o: i32?) {
    let _v: i32 = o ?? return
    println("done")
}

pub fn main() i32 {
    println(plus_one(Some(41)))
    println(plus_one(null))
    let xs: [i32?; 4] = [Some(3), null, Some(5), null]
    println(sum_present(xs))
    let ys: [i32?; 5] = [Some(1), Some(2), Some(3), null, Some(4)]
    println(count_until_missing(ys))
    note(null)
    note(Some(1))
    return 0
}
