//! TEST: rigid_copyable_branch
//! EXIT: 4

// Only the branch a rigid `T` takes is checked against it: the copy in the copyable branch is
// checked at each instantiation that reaches it.
fn first_or(xs: $T[], fallback: move T) T {
    #if type_info(T).copyable {
        if xs.len > 0 {
            return xs[0]
        }
    }
    return fallback
}

pub fn main() i32 {
    let a: [i32; 2] = [4, 5]
    const s: i32[] = a
    return first_or(s, 9)
}
