//! TEST: named_args_ufcs
//! EXIT: 14

fn offset(self: &i32, dx: i32 = 0, dy: i32 = 0) i32 {
    return self.* + dx + dy
}

pub fn main() i32 {
    let base: i32 = 10
    let r = base.offset(dy = 4)  // 10 + 0 + 4 = 14
    return r
}
