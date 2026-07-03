//! TEST: enum_match_niche_option_ref
//! EXIT: 42

// Regression for the niche-Option-match strip bug: matching `Option(&T)` where
// `T` is a tagged enum used to fail with `E3002 Unresolved identifier` for
// the `Some(p)` payload binding. LowerMatch was treating any IrPointer
// scrutinee whose pointee is an IrEnum as "auto-deref before matching" —
// which is the right move for a plain `&MyEnum` scrutinee, but wrong for
// niche-optimised `Option(&MyEnum)` (also an IrPointer whose pointee is an
// IrEnum). The fix: skip the auto-deref when the pointer is nullable, so
// the niche Option keeps its tag-check + payload-binding path inside
// LowerMatchNonEnum.

type Expr = enum {
    Ident(IdentExpr)
    Lit(i32)
}

type IdentExpr = struct {
    name: String
}

fn unwrap_lit(e: &Expr) i32 {
    return e.* match {
        Ident(_) => 0,
        Lit(n) => n,
    }
}

pub fn main() i32 {
    let lit: Expr = Expr.Lit(42)
    let opt: &Expr? = &lit
    return opt match {
        Some(p) => unwrap_lit(p),
        None => 0,
    }
}
