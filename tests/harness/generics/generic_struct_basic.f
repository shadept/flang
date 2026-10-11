//! TEST: generic_struct_basic
//! EXIT: 7

type Pair = struct(T) {
    first: T
    second: T
}

fn make_pair(a: move $T, b: move T) Pair(T) {
    return .{ first = move a, second = move b }
}

fn sum_pair(values: Pair(i32)) i32 {
    return values.first + values.second
}

pub fn main() i32 {
    let pair: Pair(i32) = make_pair(3, 4)
    return sum_pair(pair)
}
