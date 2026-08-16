//! TEST: place_nested_paths
//! EXIT: 7

// Place expressions of depth >= 2 must be ADDRESSED, not copied.
//
// Lowering a nested base as a value spills the intermediate aggregate to a
// temporary, so every place context built on it silently breaks:
//   - a mutating call writes into the temporary
//   - `&` hands back a pointer into dead stack
//   - an element store is dropped
// All three compiled clean and produced wrong results. One-hop paths always
// worked, which is why this hid for so long.
//
// See docs/spec.md "Place Expressions" and docs/adr/0003.

type Counter = struct { n: i32 }
fn incr(self: &Counter) { self.n = self.n + 1 }
fn setn(p: &Counter) { p.n = 9 }

type Holder = struct { c: Counter, arr: [i32; 3] }
type Outer  = struct { h: Holder }

pub fn main() i32 {
    let flags: i32 = 0

    // 1. mutating call through a two-hop receiver
    let a = Outer { h = Holder { c = Counter { n = 0 }, arr = [0, 0, 0] } }
    a.h.c.incr()
    if a.h.c.n == 1 { flags = flags + 1 }

    // 2. address-of a two-hop field, written through by the callee
    let b = Outer { h = Holder { c = Counter { n = 0 }, arr = [0, 0, 0] } }
    let p = &b.h.c
    setn(p)
    if b.h.c.n == 9 { flags = flags + 2 }

    // 3. element store through a two-hop base
    let c = Outer { h = Holder { c = Counter { n = 0 }, arr = [0, 0, 0] } }
    c.h.arr[1] = 5
    if c.h.arr[1] == 5 { flags = flags + 4 }

    return flags
}
