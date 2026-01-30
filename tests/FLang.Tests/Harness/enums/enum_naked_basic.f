//! TEST: enum_naked_basic
//! EXIT: 5

enum Ord {
    Less = -1
    Equal = 0
    Greater = 1
}

enum Status {
    A
    B
    C = 6
    D
}

pub fn main() i32 {
    let o: Ord = Ord.Greater
    let val: i32 = o match {
        Less => -1,
        Equal => 0,
        Greater => 1
    }

    let s: Status = Status.D
    let sval: i32 = s match {
        A => 0,
        B => 1,
        C => 6,
        D => 7
    }

    // val (1) + sval (7) - 3 = 5
    return val + sval - 3
}
