//! TEST: match_return_pattern_bound_mismatch
//! COMPILE-ERROR: E2071
//! EXIT: 1

// Hand-written equivalent of `expr?` desugar (no syntactic sugar).
// The match's `Return(r)` arm tries to `return r` where `r` is bound by the
// pattern to `Option(i32)`, but the enclosing function returns `i32`. This
// must be caught by the type checker — not deferred to the C compiler.

import std.option

fn maybe() i32? { return Some(1) }

fn caller() i32 {
    let opt: Option(i32) = maybe()
    let tr: TryResult(i32, Option(i32)) = op_try(opt)
    let v: i32 = tr match {
        Continue(x) => x,
        Return(r) => return r,
    }
    return v
}

pub fn main() i32 {
    return caller()
}
