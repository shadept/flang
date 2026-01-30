//! TEST: enum_naked_auto_increment
//! EXIT: 7

enum Example {
    A
    B
    C = 6
    D
}

pub fn main() i32 {
    let d: Example = Example.D
    return d match {
        A => 0,
        B => 1,
        C => 6,
        D => 7
    }
}
