//! TEST: enum_mutual_recursion_by_value
//! EXIT: 0

import std.list

// Regression for the cycle-break layout bug: enum SubExpr → struct
// NamedInfo → List(SubExpr) → &SubExpr. NamedInfo is a struct that
// contains SubExpr by value through `Named(NamedInfo)`. Lowering
// followed this cycle:
//   SubExpr (stub) → NamedInfo (stub) → List (full, ptr-only) →
//   NamedInfo finishes with size sized against the List stub →
//   SubExpr finishes with size sized against the (still-broken)
//   NamedInfo size.
// The deferred-relower used to re-lower NamedInfo, but SubExpr was
// never queued because the only "saw a stub" check looked at empty
// stubs, not at types that had been partially laid out against a
// stub. So `*(NamedInfo*)(&sub + 8) = info` would write 64 bytes of
// NamedInfo into a 32-byte payload slot, smashing whatever followed
// `sub` on the stack and corrupting reads of generic_args.
//
// With the fix, sizeof(SubExpr) covers the full NamedInfo payload
// and a round-trip through `SubExpr.Named(info)` + match preserves
// every field — including the late-laid-out `generic_args: List(SubExpr)`.

type SubExpr = enum {
    Named(NamedInfo)
    Unit
}

type NamedInfo = struct {
    span_start: usize
    span_length: usize
    name_len: usize
    generic_args: List(SubExpr)
}

pub fn main() i32 {
    let gargs: List(SubExpr) = list(0)
    let info: NamedInfo = .{
        span_start = 100,
        span_length = 3,
        name_len = 3,
        generic_args = gargs,
    }
    let sub: SubExpr = SubExpr.Named(info)
    return sub match {
        Named(n) => {
            if n.span_start != 100 { return 1 }
            if n.span_length != 3 { return 2 }
            if n.name_len != 3 { return 3 }
            // Pre-fix this read garbage (often the same value as name_len
            // because the SubExpr struct was too small and `generic_args`
            // overflowed past `sub` into whatever was next on the stack).
            if n.generic_args.len != 0 { return 4 }
            if n.generic_args.cap != 0 { return 5 }
            0
        }
        Unit => 99,
    }
}
