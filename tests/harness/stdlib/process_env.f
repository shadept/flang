//! TEST: process_env
//! EXIT: 0
//! SKIP: failing CI

import std.io.reader
import std.option
import std.process
import std.result
import std.string

// Verify that env(k,v) gets through to the child.
pub fn main() i32 {
    #if(platform.os == "windows") {
        let cmd = command("cmd.exe")
        defer cmd.deinit()
        cmd.arg("/c")
        cmd.arg("echo %FLANG_TEST_VAR%")
        // Don't inherit_env(): we want to confirm OUR env() arrived.
        cmd.env("FLANG_TEST_VAR", "ok-123")
        // cmd.exe needs at least SYSTEMROOT to start cleanly.
        cmd.env("SYSTEMROOT", "C:\\Windows")
        cmd.stdout_mode(Stdio.Pipe)
        const sr = cmd.spawn()
        if sr.is_err() { return 1 }
        let child = sr.unwrap()
        defer child.deinit()

        let out = child.stdout().unwrap()
        const captured = out.read_to_end()
        defer captured.deinit()
        out.close()

        const wr = child.wait()
        if wr.is_err() { return 3 }
        if wr.unwrap() != 0 { return 4 }

        if !captured.as_view().starts_with("ok-123") { return 5 }
    } else {
        let cmd = command("sh")
        defer cmd.deinit()
        cmd.arg("-c")
        cmd.arg("printf %s \"$FLANG_TEST_VAR\"")
        cmd.env("FLANG_TEST_VAR", "ok-123")
        // sh -c on most systems works with no other env vars.
        cmd.stdout_mode(Stdio.Pipe)
        const sr = cmd.spawn()
        if sr.is_err() { return 1 }
        let child = sr.unwrap()
        defer child.deinit()

        let out = child.stdout().unwrap()
        const captured = out.read_to_end()
        defer captured.deinit()
        out.close()

        const wr = child.wait()
        if wr.is_err() { return 3 }
        if wr.unwrap() != 0 { return 4 }

        if captured.as_view() != "ok-123" { return 5 }
    }
    return 0
}
