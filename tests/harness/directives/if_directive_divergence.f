//! TEST: if_directive_divergence
//! EXIT: 0

// An exhaustive #if/else whose branches both return satisfies the
// missing-return check (E2049) — no dead trailing return required.

fn pick() i32 {
    #if platform.os == "windows" {
        return 1
    } else {
        return 0
    }
}

// Divergence also flows through a #if nested behind a plain statement list.
fn pick_nested(flag: bool) i32 {
    if flag {
        #if runtime.testing {
            return 10
        } else {
            return 20
        }
    }
    return 30
}

pub fn main() i32 {
    if pick() != 0 { return 1 }
    if pick_nested(true) != 20 { return 2 }
    if pick_nested(false) != 30 { return 3 }
    return 0
}
