// `TryResult` is the desugar target for the postfix `?` operator (RFC-009).
// `expr?` lowers to `op_try(expr) match { Continue(v) => v, Return(r) => return r }`.
//
// User types opt into `?` by implementing:
//     fn op_try(self: MyType) TryResult(T, R)
// where `T` is the value to keep on the happy path and `R` is the value to
// propagate via early `return` from the enclosing function.

pub type TryResult = enum(T, R) {
    Continue(T),
    Return(R),
}
