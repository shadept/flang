//! TEST: match_all_arms_diverge_aggregate
//! EXIT: 0

// A statement-position match (or if/else) whose arms all return, in a
// function returning an aggregate: the dead merge block must not receive
// a placeholder return (only type-valid C for scalars). Regression for
// the FinishBlocks unreachable-block drop.

type Out = enum {
    A(i32)
    B(bool)
}

fn classify(n: i32) Out {
    n match {
        0 => return Out.A(0),
        else => return Out.B(true),
    }
}

fn pick(c: bool) Out {
    if c {
        return Out.A(1)
    } else {
        return Out.B(false)
    }
}

pub fn main() i32 {
    classify(0) match {
        A(x) => {
            if x != 0 { return 1 }
        },
        B(_) => return 2,
    }
    pick(true) match {
        A(x) => return x - 1,
        B(_) => return 3,
    }
}
