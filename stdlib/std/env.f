// std.env — runtime access to command-line arguments and environment variables.
//
// Arguments are views into the process's argv strings (no allocation).
// Environment variable lookups return views into the C runtime's storage.

import std.list
import std.option
import std.string
import std.test

#foreign fn __flang_get_argc() i32
#foreign fn __flang_get_arg(index: i32) &u8?
#foreign fn __flang_getenv(name: &u8) &u8?
#foreign fn strlen(s: &u8) usize

// Returns the number of command-line arguments (including the program name).
pub fn args_count() usize {
    return __flang_get_argc() as usize
}

// Returns the command-line argument at the given index, or null if out of bounds.
// Index 0 is the program name.
pub fn arg(index: usize) String? {
    const ptr = __flang_get_arg(index as i32)
    if ptr.is_none() { return null }
    const len = strlen(ptr.value)
    return slice_from_raw_parts(ptr.value, len) as String
}

// Returns all command-line arguments as a List(String).
// Caller must call deinit() when done.
pub fn get_args() List(String) {
    const count = args_count()
    let result: List(String) = list(count)
    let i: usize = 0
    loop {
        if i >= count { break }
        const a = arg(i)
        if a.is_some() {
            result.push(a.value)
        }
        i = i + 1
    }
    return result
}

// Returns the value of the environment variable with the given key,
// or null if the variable is not set.
pub fn get(key: String) String? {
    const ptr = __flang_getenv(key.ptr)
    if ptr.is_none() { return null }
    const len = strlen(ptr.value)
    return slice_from_raw_parts(ptr.value, len) as String
}

// =============================================================================
// getopt — command-line option parsing
// =============================================================================
//
// Format string: each char is a short option. ':' after = takes argument.
// '(name)' after = long alias.  e.g. "v(verbose)o:(output)h(help)"
//
// Usage:
//   let a = get_args()
//   defer a.deinit()
//   let opts = getopts("vho:(output)", a.as_slice())
//   opts.index = 1  // skip argv[0]
//   loop {
//       const r = opts.next()
//       match r { .Opt(ch) => ..., .OptArg(ch, val) => ..., .Done => break }
//   }

pub type OptResult = enum {
    Opt(u8)
    OptArg(u8, String)
    NonOpt(String)
    Error(u8)
    MissingArg(u8)
}

pub type GetOpt = struct {
    format: String
    args: String[]
    index: usize
    pos: usize
    done: bool
}

pub fn getopts(format: String, args: String[]) GetOpt {
    let result: GetOpt
    result.format = format
    result.args = args
    result.index = 0
    result.pos = 0
    result.done = false
    return result
}

// Look up short option in format. Returns 0=not found, 1=flag, 2=takes arg.
fn lookup_short(format: String, ch: u8) u8 {
    let i: usize = 0
    loop {
        if i >= format.len { return 0 }
        let c = format[i]
        if c == b'(' {
            i = i + 1
            loop {
                if i >= format.len { return 0 }
                if format[i] == b')' {
                    i = i + 1
                    break
                }
                i = i + 1
            }
            continue
        }
        if c == b':' {
            i = i + 1
            continue
        }
        if c == ch {
            if i + 1 < format.len and format[i + 1] == b':' { return 2 }
            return 1
        }
        i = i + 1
    }
    return 0
}

// Find long name in format, return associated short char (or 0).
fn lookup_long(format: String, name: String) u8 {
    let i: usize = 0
    let last_opt: u8 = 0
    loop {
        if i >= format.len { return 0 }
        let c = format[i]
        if c == b'(' {
            let start = i + 1
            i = start
            loop {
                if i >= format.len { return 0 }
                if format[i] == b')' { break }
                i = i + 1
            }
            const long = slice_from_raw_parts(format.ptr + start, i - start) as String
            i = i + 1
            if long == name { return last_opt }
            continue
        }
        if c == b':' {
            i = i + 1
            continue
        }
        last_opt = c
        i = i + 1
    }
    return 0
}

pub fn next(self: &GetOpt) OptResult? {
    loop {
        if self.index >= self.args.len { return null }
        const a = self.args[self.index]

        // Inside combined short flags: -lwc
        if self.pos > 0 {
            const ch = a[self.pos]
            self.pos = self.pos + 1
            if self.pos >= a.len {
                self.pos = 0
                self.index = self.index + 1
            }
            const kind = lookup_short(self.format, ch)
            if kind == 0 { return OptResult.Error(ch) }
            if kind == 2 {
                if self.pos > 0 {
                    // Rest of arg is the value: -ofilename
                    const val = slice_from_raw_parts(a.ptr + self.pos, a.len - self.pos) as String
                    self.pos = 0
                    self.index = self.index + 1
                    return OptResult.OptArg(ch, val)
                }
                // Next arg is the value
                if self.index >= self.args.len { return OptResult.MissingArg(ch) }
                const val = self.args[self.index]
                self.index = self.index + 1
                return OptResult.OptArg(ch, val)
            }
            return OptResult.Opt(ch)
        }

        // -- stops option processing
        if self.done {
            self.index = self.index + 1
            return OptResult.NonOpt(a)
        }

        if a == "--" {
            self.index = self.index + 1
            self.done = true
            continue
        }

        // Long option: --name or --name=value
        if a.starts_with("--") {
            self.index = self.index + 1
            // Find '=' for inline value
            let eq_pos = 2usize
            loop {
                if eq_pos >= a.len { break }
                if a[eq_pos] == b'=' { break }
                eq_pos = eq_pos + 1
            }
            const name = slice_from_raw_parts(a.ptr + 2usize, eq_pos - 2usize) as String
            const ch = lookup_long(self.format, name)
            if ch == 0 { return OptResult.Error(b'?') }
            const kind = lookup_short(self.format, ch)
            if kind == 2 {
                if eq_pos < a.len {
                    const val = slice_from_raw_parts(a.ptr + eq_pos + 1usize, a.len - eq_pos - 1usize) as String
                    return OptResult.OptArg(ch, val)
                }
                if self.index >= self.args.len { return OptResult.MissingArg(ch) }
                const val = self.args[self.index]
                self.index = self.index + 1
                return OptResult.OptArg(ch, val)
            }
            return OptResult.Opt(ch)
        }

        // Short option(s): -x or -xyz
        if a.len > 1 and a[0] == b'-' {
            self.pos = 1
            continue
        }

        // Non-option argument
        self.index = self.index + 1
        return OptResult.NonOpt(a)
    }
    return null
}

// After parsing, returns the index of the first non-option argument
// remaining (useful when done processing flags).
pub fn rest_index(self: &GetOpt) usize {
    return self.index
}

test "args_count returns at least 1" {
    assert_true(args_count() >= 1, "should have at least program name")
}

test "arg 0 is program name" {
    const a = arg(0)
    assert_true(a.is_some(), "arg 0 should exist")
    assert_true(a.value.len > 0, "program name should be non-empty")
}

test "arg out of bounds returns null" {
    const a = arg(999999)
    assert_true(a.is_none(), "out of bounds should return null")
}

test "get_args returns all args" {
    let a = get_args()
    defer a.deinit()
    assert_true(a.len >= 1, "should have at least program name")
    const s = a.as_slice()
    assert_true(s.len >= 1, "slice should have at least one entry")
    assert_true(s[0].len > 0, "program name should be non-empty")
}

test "get existing env var" {
    const path = get("PATH")
    assert_true(path.is_some(), "PATH should be set")
    assert_true(path.value.len > 0, "PATH should be non-empty")
}

test "get missing env var returns null" {
    const val = get("__FLANG_NONEXISTENT_VAR_12345__")
    assert_true(val.is_none(), "nonexistent var should return null")
}

fn expect_opt(r: OptResult?, expected: u8, msg: String) {
    assert_true(r.is_some(), msg)
    const ch = r.value match { Opt(c) => c, _ => 0 }
    assert_eq(ch, expected, msg)
}

fn expect_optarg(r: OptResult?, expected_ch: u8, expected_val: String, msg: String) {
    assert_true(r.is_some(), msg)
    const ch = r.value match { OptArg(c, _) => c, _ => 0 }
    assert_eq(ch, expected_ch, msg)
}

fn expect_nonopt(r: OptResult?, expected: String, msg: String) {
    assert_true(r.is_some(), msg)
    const val = r.value match { NonOpt(s) => s, _ => "" }
    assert_eq(val, expected, msg)
}

fn expect_done(r: OptResult?, msg: String) {
    assert_true(r.is_none(), msg)
}

test "getopts simple flags" {
    let args = ["-l", "-w", "-c"]
    let opts = getopts("lwc", args)
    expect_opt(opts.next(), b'l', "flag l")
    expect_opt(opts.next(), b'w', "flag w")
    expect_opt(opts.next(), b'c', "flag c")
    expect_done(opts.next(), "done")
}

test "getopts combined flags" {
    let args = ["-lwc"]
    let opts = getopts("lwc", args)
    expect_opt(opts.next(), b'l', "combined l")
    expect_opt(opts.next(), b'w', "combined w")
    expect_opt(opts.next(), b'c', "combined c")
    expect_done(opts.next(), "done")
}

test "getopts option with argument" {
    let args = ["-o", "file.txt"]
    let opts = getopts("o:", args)
    expect_optarg(opts.next(), b'o', "file.txt", "opt with arg")
    expect_done(opts.next(), "done")
}

test "getopts option with inline argument" {
    let args = ["-ofile.txt"]
    let opts = getopts("o:", args)
    expect_optarg(opts.next(), b'o', "file.txt", "inline arg")
    expect_done(opts.next(), "done")
}

test "getopts long option" {
    let args = ["--verbose"]
    let opts = getopts("v(verbose)", args)
    expect_opt(opts.next(), b'v', "long verbose")
    expect_done(opts.next(), "done")
}

test "getopts long option with value" {
    let args = ["--output=file.txt"]
    let opts = getopts("o:(output)", args)
    expect_optarg(opts.next(), b'o', "file.txt", "long with =")
    expect_done(opts.next(), "done")
}

test "getopts long option with next arg value" {
    let args = ["--output", "file.txt"]
    let opts = getopts("o:(output)", args)
    expect_optarg(opts.next(), b'o', "file.txt", "long next arg")
    expect_done(opts.next(), "done")
}

test "getopts non-option args" {
    let args = ["-l", "foo.txt", "bar.txt"]
    let opts = getopts("lwc", args)
    expect_opt(opts.next(), b'l', "flag")
    expect_nonopt(opts.next(), "foo.txt", "file 1")
    expect_nonopt(opts.next(), "bar.txt", "file 2")
    expect_done(opts.next(), "done")
}

test "getopts double dash stops options" {
    let args = ["-l", "--", "-w"]
    let opts = getopts("lwc", args)
    expect_opt(opts.next(), b'l', "flag before --")
    expect_nonopt(opts.next(), "-w", "-w is non-opt after --")
    expect_done(opts.next(), "done")
}

test "getopts mixed short long and files" {
    let args = ["-v", "--output=out.txt", "input.f"]
    let opts = getopts("v(verbose)o:(output)", args)
    expect_opt(opts.next(), b'v', "short v")
    expect_optarg(opts.next(), b'o', "out.txt", "long output")
    expect_nonopt(opts.next(), "input.f", "file arg")
    expect_done(opts.next(), "done")
}

test "getopts with index skip" {
    let args = ["prog", "-v", "file.txt"]
    let opts = getopts("v", args)
    opts.index = 1
    expect_opt(opts.next(), b'v', "flag v")
    expect_nonopt(opts.next(), "file.txt", "file arg")
    expect_done(opts.next(), "done")
}
