//! TEST: named_default_combo
//! EXIT: 13

fn make(a: i32, b: i32 = 5, c: i32 = 8) i32 {
    return a + b + c
}

pub fn main() i32 {
    // Skip b (use default 5), provide c by name
    let r = make(1, c = 7)  // 1 + 5 + 7 = 13
    return r
}
