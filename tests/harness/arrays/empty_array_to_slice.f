//! TEST: empty_array_to_slice
//! EXIT: 0

// Regression: `let xs: T[] = []` previously crashed the C compiler with
// `use of undeclared identifier 'alloca_N'`. The empty-array literal's
// alloca was being kept alive only via a downstream cast that referenced it
// by name through a freshly-constructed LocalValue, but DCE counted uses by
// reference identity and removed the alloca — leaving the cast pointing at
// an undeclared symbol.

fn count(xs: i32[]) usize {
    let total: usize = 0
    for x in xs { total = total + 1 }
    return total
}

pub fn main() i32 {
    let empty: i32[] = []
    if count(empty) != 0 { return 1 }

    let two: i32[] = [10, 20]
    if count(two) != 2 { return 2 }

    return 0
}
