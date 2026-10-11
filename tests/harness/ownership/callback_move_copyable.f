//! TEST: callback_move_copyable
//! EXIT: 12

fn each(s: $T[], f: $F) where F: fn(move T) {
    for i in 0..s.len {
        f(s[i])
    }
}

let total: i32 = 0

fn add(v: move i32) {
    total = total + v
}

// `move` on a copyable element is a copy, as `let b = xs[0]` is.
pub fn main() i32 {
    let xs: [i32; 3] = [1, 2, 3]
    each(xs, add)
    each(xs, fn(v: move i32) { total = total + v })
    return total
}
