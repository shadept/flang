// Core optional value support. `Option(T)` is the canonical sum type used
// for "either a value of type T or nothing". The preferred surface syntax
// uses `T?` and `null` — the latter desugars to `Option.None` with `T`
// inferred from context.
//
// Layout note: `Option(&T)` is niche-optimized to a nullable pointer
// (a 0 pointer encodes `None`); other `Option(T)` use a tagged-enum
// representation. See `docs/spec.md` §2.7 for details.

// `None` is declared first so it gets discriminant tag 0. Many call sites
// rely on zero-initialized memory representing `None` (e.g. struct fields
// of type `Option(T)` with no explicit initializer).
pub type Option = enum(T) {
    None,
    Some(T),
}

// `op_try` for Option: `Some(v)` → continue with `v`, `None` → return `None`.
// Lets `expr?` work in any function whose return type is `Option(_)`.
pub fn op_try(self: Option($T)) TryResult(T, Option(T)) {
    return self match {
        Some(v) => TryResult.Continue(v),
        None => TryResult.Return(None),
    }
}

pub fn op_eq(a: Option($T), b: Option(T)) bool {
    return a match {
        Some(av) => b match {
            Some(bv) => av == bv,
            None => false,
        },
        None => b match {
            Some(_) => false,
            None => true,
        },
    }
}
