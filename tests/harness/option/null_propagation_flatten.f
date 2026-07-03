//! TEST: null_propagation_flatten
//! STDOUT: PASS

type Inner = struct {
    name: String
}

type Middle = struct {
    inner: Option(Inner)
}

type Outer = struct {
    middle: Option(Middle)
}

// `mid?.inner` where `inner` is itself `Option(Inner)` flattens to
// `Option(Inner)` (not `Option(Option(Inner))`) per RFC-010 §"`?.` flattens".
fn read_inner(mid: Option(Middle)) String {
    let inner_opt = mid?.inner
    return inner_opt match {
        Some(i) => i.name,
        None => "missing",
    }
}

pub fn main() i32 {
    let pass = true

    let m_some = Middle { inner = Inner { name = "alice" } }
    let m_none: Middle = Middle { inner = null }

    if read_inner(m_some) != "alice" { println("FAIL: outer Some, inner Some"); pass = false }
    if read_inner(m_none) != "missing" { println("FAIL: outer Some, inner None"); pass = false }
    if read_inner(null) != "missing" { println("FAIL: outer None"); pass = false }

    if pass { println("PASS") }
    return 0
}
