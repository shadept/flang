//! TEST: process_basic
//! EXIT: 0
//! SKIP: failing CI

import std.option
import std.process
import std.result
import std.string

pub fn main() i32 {
    // Spawn the platform "echo exit code" equivalent: invoke ourselves through
    // a portable command. `cmd /c exit N` on Windows; `sh -c "exit N"` on POSIX.
    #if(platform.os == "windows") {
        // cmd /c exit 42
        let cmd = command("cmd.exe")
        defer cmd.deinit()
        cmd.arg("/c")
        cmd.arg("exit")
        cmd.arg("42")
        cmd.inherit_env()
        const sr = cmd.spawn()
        if sr.is_err() { return 1 }
        let child = sr.unwrap()
        defer child.deinit()
        const wr = child.wait()
        if wr.is_err() { return 2 }
        if wr.unwrap() != 42 { return 3 }
    } else {
        let cmd = command("sh")
        defer cmd.deinit()
        cmd.arg("-c")
        cmd.arg("exit 42")
        cmd.inherit_env()
        const sr = cmd.spawn()
        if sr.is_err() { return 1 }
        let child = sr.unwrap()
        defer child.deinit()
        const wr = child.wait()
        if wr.is_err() { return 2 }
        if wr.unwrap() != 42 { return 3 }
    }
    return 0
}
