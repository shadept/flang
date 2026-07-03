//! TEST: specialization_ranking
//! EXIT: 20

// Fully generic: 2 quantified vars ($T, $U)
fn pick(a: $T, b: $U) i32 {
    return 10
}

// Partially specialized: 1 quantified var ($T), b constrained to same T
fn pick(a: $T, b: T) i32 {
    return 20
}

pub fn main() i32 {
    let x: i32 = 5

    // Both overloads match (i32, i32), but fewer type vars wins → 20
    return pick(x, x)
}
