//! TEST: type_struct_generic
//! EXIT: 7

type Pair = struct(T) {
    a: T
    b: T
}

fn make_pair(x: move $T, y: move T) Pair(T) {
    return .{ a = move x, b = move y }
}

pub fn main() i32 {
    let p: Pair(i32) = make_pair(3, 4)
    return p.a + p.b
}
