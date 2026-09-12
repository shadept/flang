//! TEST: ref_form_op_eq
//! EXIT: 7
//! SKIP: `==` cannot reach an `op_eq` over `&T` until RFC-030 lands; see docs/tickets/030

// A non-copyable type declares `op_eq` over `&T`. `h == g` reaches it with the operands addressed,
// not copied, and `p == q` on two references reaches the same call. Identity is `addr_eq`.

type Handle = struct {
    owned fd: i32
}

fn op_eq(a: &Handle, b: &Handle) bool {
    return a.fd == b.fd
}

fn main() i32 {
    let h: Handle = Handle { fd = 3 }
    let g: Handle = Handle { fd = 3 }
    let p: &Handle = &h
    let q: &Handle = &g

    let direct: bool = op_eq(&h, &g)     // fields equal             -> true   (1)
    let via_op: bool = h == g            // rung 4, no copy          -> true   (2)
    let via_ref: bool = p == q           // pointees, rung 4         -> true   (4)
    let same: bool = addr_eq(p, q)       // distinct objects         -> false  (8)

    return (if direct { 1 } else { 0 })
         + (if via_op { 2 } else { 0 })
         + (if via_ref { 4 } else { 0 })
         + (if same { 8 } else { 0 })
}
