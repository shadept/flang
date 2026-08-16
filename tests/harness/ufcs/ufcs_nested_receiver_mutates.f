//! TEST: ufcs_nested_receiver_mutates
//! EXIT: 111

// A UFCS receiver that is a multi-hop field path must be passed by
// address, not as a copy. Lowering the intermediate member access as a
// value spills it to a temp, so the callee mutates the temp and the
// write is silently lost — with no diagnostic.
//
// One hop always worked; two and three hops did not. All three are
// pinned here so the depths cannot diverge again.

type Counter = struct { n: i32 }

fn incr(self: &Counter) {
    self.n = self.n + 1
}

type Mid   = struct { c: Counter }
type Outer = struct { mid: Mid }

// receiver `self.c` — one hop
fn via1(self: &Mid) {
    self.c.incr()
}

// receiver `self.mid.c` — two hops
fn via2(self: &Outer) {
    self.mid.c.incr()
}

pub fn main() i32 {
    let m = Mid { c = Counter { n = 0 } }
    via1(&m)

    let o = Outer { mid = Mid { c = Counter { n = 0 } } }
    via2(&o)

    // A three-hop receiver written directly at the call site.
    let o2 = Outer { mid = Mid { c = Counter { n = 0 } } }
    o2.mid.c.incr()

    return m.c.n * 100 + o.mid.c.n * 10 + o2.mid.c.n
}
