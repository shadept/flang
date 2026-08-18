//! TEST: index_ref_to_array
//! EXIT: 7

// `&[T; N]` used to lower to `T**` while every caller passed `T*`, and the
// array-to-slice decay that `xs[i]` resolves to was type-checked but never
// emitted — the index operator's arguments skipped the coercion step that
// ordinary calls go through. Both showed up as C compile errors rather than
// wrong answers, but only because C is typed; the same two gaps on a
// same-width type would have been silent.
//
// The reference is a plain `T*` now (an array value already IS the address
// of its storage), which costs the IR type its length — so the decay reads
// `N` off the semantic type instead. See HmAstLowering.DecayIndexBase.

fn first(xs: &[i32; 4]) i32 {
    return xs[0usize]
}

fn last(xs: &[i32; 4]) i32 {
    return xs[3usize]
}

fn sum_slice(xs: i32[]) i32 {
    let t = 0
    for i in 0..xs.len { t = t + xs[i] }
    return t
}

pub fn main() i32 {
    let flags: i32 = 0
    let a: [i32; 4] = [10, 20, 30, 40]

    // 1. index through a reference to a fixed array
    if first(&a) == 10 { flags = flags + 1 }

    // 2. the last element, so a wrong stride shows up rather than aliasing
    //    element 0
    if last(&a) == 40 { flags = flags + 2 }

    // 3. the array itself still decays at an ordinary call site
    if sum_slice(a) == 100 { flags = flags + 4 }

    return flags
}
