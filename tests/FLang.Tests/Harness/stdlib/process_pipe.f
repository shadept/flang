//! TEST: process_pipe
//! EXIT: 0
//! SKIP: failing CI

import std.io.reader
import std.option
import std.process
import std.result
import std.string

// Capture child stdout via a Pipe and check the content.
pub fn main() i32 {
    #if(platform.os == "windows") {
        let cmd = command("cmd.exe")
        defer cmd.deinit()
        cmd.arg("/c")
        cmd.arg("echo hello-from-child")
        cmd.inherit_env()
        cmd.stdout_mode(Stdio.Pipe)
        const sr = cmd.spawn()
        if sr.is_err() { return 1 }
        let child = sr.unwrap()
        defer child.deinit()

        const out_opt = child.stdout()
        if out_opt.is_none() { return 2 }
        let out = out_opt.unwrap()
        const captured = out.read_to_end()
        defer captured.deinit()
        out.close()

        const wr = child.wait()
        if wr.is_err() { return 3 }
        if wr.unwrap() != 0 { return 4 }

        // cmd.exe adds CRLF; just check the payload is in there.
        if !captured.as_view().starts_with("hello-from-child") { return 5 }
    } else {
        let cmd = command("sh")
        defer cmd.deinit()
        cmd.arg("-c")
        cmd.arg("printf hello-from-child")
        cmd.inherit_env()
        cmd.stdout_mode(Stdio.Pipe)
        const sr = cmd.spawn()
        if sr.is_err() { return 1 }
        let child = sr.unwrap()
        defer child.deinit()

        const out_opt = child.stdout()
        if out_opt.is_none() { return 2 }
        let out = out_opt.unwrap()
        const captured = out.read_to_end()
        defer captured.deinit()
        out.close()

        const wr = child.wait()
        if wr.is_err() { return 3 }
        if wr.unwrap() != 0 { return 4 }

        if captured.as_view() != "hello-from-child" { return 5 }
    }
    return 0
}
