//! TEST: variadic_basic
//! EXIT: 15

fn sum(..nums: i32) i32 {
    let total: i32 = 0
    for n in nums {
        total = total + n
    }
    return total
}

pub fn main() i32 {
    return sum(1, 2, 3, 4, 5)
}
