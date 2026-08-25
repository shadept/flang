//! TEST: eval_order_out_param_read_after_call
//! EXIT: 0
//! STDOUT: 7
//! STDOUT: 42

// The out-parameter shape std.io.internal.fs is built on: a call writes
// through a pointer, and a later argument in the SAME expression reads what it
// wrote. Correct only because arguments evaluate left to right (spec 5.1.1) -
// right-to-left would report err as 0.

fn writes_out(out: &i32) i32 {
    out.* = 42
    return 7
}

fn report(status: i32, err: i32) {
    println(status)
    println(err)
}

pub fn main() i32 {
    let err: i32 = 0
    report(writes_out(&err), err)
    return 0
}
