//! TEST: process_arg_with_nul
//! EXIT: 0

import std.option
import std.process
import std.result
import std.string

// An argument holding a NUL has no C spelling: spawn refuses it rather than run the child with the
// text cut at the NUL. The refusal comes before any process exists, so the program never runs.
pub fn main() i32 {
    let cmd = command("flang-no-such-program")
    defer cmd.deinit()
    cmd.arg("a\0b")
    const sr = cmd.spawn()
    return sr match {
        Ok(child) => {
            child.deinit()
            1
        }
        Err(e) => if e == ProcessError.InvalidArgument { 0 } else { 2 }
    }
}
