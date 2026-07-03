//! TEST: variadic_with_fixed
//! EXIT: 30

fn sum_with_base(base: i32, ..nums: i32) i32 {
    let total: i32 = base
    for n in nums {
        total = total + n
    }
    return total
}

pub fn main() i32 {
    return sum_with_base(10, 5, 7, 8)  // 10 + 5 + 7 + 8 = 30
}
