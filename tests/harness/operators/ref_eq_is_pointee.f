//! TEST: ref_eq_is_pointee
//! EXIT: 11
//! SKIP: `&T == &T` is address equality until RFC-030 lands; see docs/tickets/030

// `&T == &T` compares the pointees through `T`'s `op_eq`. Identity is `addr_eq`.

type Pt = struct {
    x: i32
}

fn op_eq(a: Pt, b: Pt) bool {
    return a.x == b.x
}

fn main() i32 {
    let a: Pt = Pt { x = 1 }
    let b: Pt = Pt { x = 1 }
    let p: &Pt = &a
    let q: &Pt = &b
    let r: &Pt = &a

    let by_value: bool = a == b          // op_eq                  -> true   (1)
    let by_ref: bool = p == q            // op_eq on the pointees  -> true   (2)
    let addr_pq: bool = addr_eq(p, q)    // distinct objects       -> false  (4)
    let addr_pr: bool = addr_eq(p, r)    // same object            -> true   (8)

    return (if by_value { 1 } else { 0 })
         + (if by_ref { 2 } else { 0 })
         + (if addr_pq { 4 } else { 0 })
         + (if addr_pr { 8 } else { 0 })
}
