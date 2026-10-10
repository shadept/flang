//! TEST: child_pipe_not_copyable
//! COMPILE-ERROR: E2124
//! EXIT: 1

import std.option
import std.process
import std.result

// A pipe taken from a child owns its descriptor.
pub fn main() i32 {
    let cmd = command("true")
    defer cmd.deinit()
    cmd.stdout_mode(Stdio.Pipe)
    let c = cmd.spawn().unwrap()
    defer c.deinit()
    let out = c.stdout().unwrap()
    let again = out // error E2124
    again.close()
    return 0
}
