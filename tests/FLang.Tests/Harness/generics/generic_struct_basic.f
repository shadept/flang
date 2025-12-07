//! TEST: generic_struct_basic
//! EXIT: 7

struct Pair(T) {
    first: T
    second: T
}

fn make_pair(a: $T, b: T) Pair(T) {
    return .{ first = a, second = b }
}

fn sum_pair(values: Pair(i32)) i32 {
    return values.first + values.second
}

pub fn main() i32 {
    let pair: Pair(i32) = make_pair(3, 4)
    return sum_pair(pair)
}
