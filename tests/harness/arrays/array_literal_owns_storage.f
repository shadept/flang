//! TEST: array_literal_owns_storage
//! EXIT: 0

// A literal at an array type is that array: a binding, a parameter or a default owns its storage,
// so writes stay in the copy that made them. The test exits with the number of the first position
// that reads the wrong value.

fn count(xs: i64[]) usize {
    return xs.len
}

fn first_plus_last(xs: [i64; 3]) i64 {
    xs[0] = 7
    return xs[0] + xs[2]
}

fn defaulted(xs: [i64; 3] = [1i64, 2, 3]) i64 {
    xs[0] = 7
    return xs[0] + xs[2]
}

fn check(got: i64, want: i64, position: i32) i32 {
    if got == want {
        return 0
    }
    return position
}

// The first nonzero position, so the exit code names the one that failed.
fn first(failed: i32, next: i32) i32 {
    if failed != 0 {
        return failed
    }
    return next
}

pub fn main() i32 {
    let failed: i32 = 0

    let typed: [i64; 3] = [7i64, 8, 9]
    typed[0] = 1
    failed = first(failed, check(typed.len as i64, 3, 1))
    failed = first(failed, check(typed[0], 1, 2))

    // An unannotated binding is the array, so a copy is its own storage even after a slice use.
    let local = [1i64, 2, 3]
    failed = first(failed, check(count(local) as i64, 3, 3))
    let copy = local
    copy[0] = 9
    failed = first(failed, check(local[0], 1, 4))

    // Nested literals are owned too: a copy of the rows shares none of their storage.
    let grid = [[1i64, 2], [3i64, 4]]
    let other = grid
    other[0][0] = 9
    failed = first(failed, check(grid[0][0], 1, 5))

    // A literal argument at an array parameter is the callee's own array.
    failed = first(failed, check(first_plus_last([1i64, 2, 3]), 10, 6))
    let src = [1i64, 2, 3]
    failed = first(failed, check(first_plus_last(src), 10, 7))
    failed = first(failed, check(src[0], 1, 8))

    // A default at an array type is fresh on every call.
    failed = first(failed, check(defaulted(), 10, 9))
    failed = first(failed, check(defaulted(), 10, 10))
    return failed
}
