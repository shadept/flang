//! TEST: null_propagation_wrap_chain
//! STDOUT: PASS

// `p?.x` wraps a non-Option field into `Option(field)` (RFC-010);
// chained `a?.b?.c` projects through each Option without re-wrapping.

type P = struct {
    x: i64
    name: String
}

type B = struct {
    p: Option(P)
}

type A = struct {
    b: Option(B)
}

fn get_x(p: Option(P)) i64 {
    return p?.x ?? -1
}

fn get_name(p: Option(P)) String {
    return p?.name ?? "none"
}

fn deep_x(a: Option(A)) i64 {
    return a?.b?.p?.x ?? -1
}

pub fn main() i32 {
    let pass = true
    let some = Some(P { x = 42, name = "alice" })

    if get_x(some) != 42 { println("FAIL: wrap scalar Some"); pass = false }
    if get_x(null) != -1 { println("FAIL: wrap scalar None"); pass = false }
    if get_name(some) != "alice" { println("FAIL: wrap aggregate Some"); pass = false }
    if get_name(null) != "none" { println("FAIL: wrap aggregate None"); pass = false }

    let full = Some(A { b = Some(B { p = some }) })
    let cut = Some(A { b = Some(B { p = null }) })
    let stub = Some(A { b = null })
    if deep_x(full) != 42 { println("FAIL: full chain"); pass = false }
    if deep_x(cut) != -1 { println("FAIL: inner None"); pass = false }
    if deep_x(stub) != -1 { println("FAIL: middle None"); pass = false }
    if deep_x(null) != -1 { println("FAIL: outer None"); pass = false }

    if pass { println("PASS") }
    return 0
}
