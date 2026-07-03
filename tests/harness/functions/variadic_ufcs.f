//! TEST: variadic_ufcs
//! EXIT: 16

fn add_all(self: &i32, ..extras: i32) i32 {
    let total: i32 = self.*
    for n in extras {
        total = total + n
    }
    return total
}

pub fn main() i32 {
    let base: i32 = 10
    return base.add_all(1, 2, 3)  // 10 + 1 + 2 + 3 = 16
}
