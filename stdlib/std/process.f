// std.process — spawn and manage child processes.
//
// Usage:
//   let cmd = command("clang")
//   defer cmd.deinit()
//   cmd.arg("-O2").arg("-c").arg("foo.c")
//   cmd.inherit_env()                // toolchain needs PATH etc.
//   let child = cmd.spawn().unwrap()
//   defer child.deinit()
//   const exit = child.wait().unwrap()
//
// Stdio:
//   By default stdin/stdout/stderr are Inherited from the parent. Switch
//   to Pipe to capture or feed bytes. Captured streams are exposed as
//   Reader / Writer through child.stdout() / child.stderr() / child.stdin().
//
// Environment:
//   Default env is empty. `env(k, v)` adds one pair. `envs(pairs)` adds many.
//   `inherit_env()` snapshots the parent process environment — call this
//   before any explicit `env()` overrides if you want both.

import std.allocator
import std.io.reader
import std.io.writer
import std.interface
import std.list
import std.mem
import std.option
import std.result
import std.string
import std.string_builder

// =============================================================================
// Public types
// =============================================================================

pub type ProcessError = enum {
    NotFound
    PermissionDenied
    IOError
    InvalidArgument
}

pub type Stdio = enum {
    Inherit = 0
    Null = 1
    Pipe = 2
}

pub type Command = struct {
    // argv[0] is the program path/name. The C side passes it as both `prog`
    // and `argv[0]` so PATH-based lookup works without losing argv[0].
    __args: List(OwnedString)
    __env_pairs: List(OwnedString)        // each entry pre-joined "KEY=VALUE"
    __cwd: OwnedString?
    __has_cwd: bool
    __stdin: i32
    __stdout: i32
    __stderr: i32
    __allocator: &Allocator?
}

pub type Child = struct {
    __handle: usize         // OS-specific (PID on POSIX, HANDLE bits on Windows)
    __stdin_fd: i32         // -1 when not piped or already taken
    __stdout_fd: i32
    __stderr_fd: i32
    __finished: bool
    __exit_code: i32
}

pub type ChildStdout = struct { __fd: i32 }
pub type ChildStderr = struct { __fd: i32 }
pub type ChildStdin = struct { __fd: i32 }

// =============================================================================
// Foreign ABI
// =============================================================================

#foreign fn __flang_proc_spawn(
    prog: &u8,
    argv: &usize, argc: usize,
    envp: &usize, envc: usize,
    cwd: &u8?, has_cwd: i32,
    stdin_mode: i32, stdout_mode: i32, stderr_mode: i32,
    out_handle: &usize,
    out_stdin_fd: &i32, out_stdout_fd: &i32, out_stderr_fd: &i32,
    out_err: &i32,
) i32

#foreign fn __flang_proc_wait(handle: usize, out_exit: &i32, out_err: &i32) i32
#foreign fn __flang_proc_kill(handle: usize, out_err: &i32) i32
#foreign fn __flang_proc_release(handle: usize)

#foreign fn __flang_proc_read(fd: i32, buf: &u8, cap: usize) isize
#foreign fn __flang_proc_write(fd: i32, buf: &u8, len: usize) isize
#foreign fn __flang_proc_close_fd(fd: i32)

#foreign fn __flang_proc_env_count() usize
#foreign fn __flang_proc_env_at(index: usize) &u8?

// =============================================================================
// Command builder
// =============================================================================

// Create a new Command for `prog`. By default no env vars are passed to the
// child — call `inherit_env()` if your child needs PATH and friends.
pub fn command(prog: String, allocator: &Allocator? = null) Command {
    let argv: List(OwnedString) = list(4, allocator)
    argv.push(from_view(prog, allocator))
    let envs: List(OwnedString) = list(0, allocator)
    return .{
        __args = argv,
        __env_pairs = envs,
        __cwd = null,
        __has_cwd = false,
        __stdin = Stdio.Inherit as i32,
        __stdout = Stdio.Inherit as i32,
        __stderr = Stdio.Inherit as i32,
        __allocator = allocator,
    }
}

pub fn deinit(self: &Command) {
    for i in 0..self.__args.len {
        let a = self.__args[i]
        a.deinit()
    }
    self.__args.deinit()
    for i in 0..self.__env_pairs.len {
        let e = self.__env_pairs[i]
        e.deinit()
    }
    self.__env_pairs.deinit()
    if self.__has_cwd {
        self.__cwd match {
            Some(c) => {
                let cc = c
                cc.deinit()
            },
            None => {},
        }
    }
}

pub fn arg(self: &Command, a: String) &Command {
    self.__args.push(from_view(a, self.__allocator))
    return self
}

pub fn args(self: &Command, items: String[]) &Command {
    for i in 0..items.len {
        self.__args.push(from_view(items[i], self.__allocator))
    }
    return self
}

pub fn cwd(self: &Command, dir: String) &Command {
    // Free a previously-set cwd before overwriting so a second call doesn't leak.
    if self.__has_cwd {
        self.__cwd match {
            Some(c) => {
                let cc = c
                cc.deinit()
            },
            None => {},
        }
    }
    self.__cwd = from_view(dir, self.__allocator)
    self.__has_cwd = true
    return self
}

// Add a single KEY=VALUE pair to the child environment.
pub fn env(self: &Command, key: String, val: String) &Command {
    let sb = string_builder(key.len + val.len + 2, self.__allocator)
    sb.append(key)
    sb.append_byte('=')
    sb.append(val)
    self.__env_pairs.push(sb.to_string())
    return self
}

// Snapshot the current process environment into the command. Call this
// before adding explicit env() overrides to start from the parent env
// rather than the empty default.
pub fn inherit_env(self: &Command) &Command {
    const n = __flang_proc_env_count()
    for i in 0..n {
        const p_opt = __flang_proc_env_at(i)
        p_opt match {
            Some(p) => {
                self.__env_pairs.push(from_view(from_c_string(p), self.__allocator))
            },
            None => {},
        }
    }
    return self
}

pub fn stdin_mode(self: &Command, m: Stdio) &Command {
    self.__stdin = m as i32
    return self
}

pub fn stdout_mode(self: &Command, m: Stdio) &Command {
    self.__stdout = m as i32
    return self
}

pub fn stderr_mode(self: &Command, m: Stdio) &Command {
    self.__stderr = m as i32
    return self
}

// =============================================================================
// Spawning
// =============================================================================

pub fn spawn(self: &Command) Result(Child, ProcessError) {
    if self.__args.len == 0 {
        return Err(ProcessError.InvalidArgument)
    }

    // Pack argv pointers as a usize array — matches char** on the C side.
    let argv_ptrs: List(usize) = list(self.__args.len, self.__allocator)
    defer argv_ptrs.deinit()
    for i in 0..self.__args.len {
        const a = self.__args[i]
        argv_ptrs.push(a.ptr as usize)
    }

    let envp_ptrs: List(usize) = list(self.__env_pairs.len, self.__allocator)
    defer envp_ptrs.deinit()
    for i in 0..self.__env_pairs.len {
        const e = self.__env_pairs[i]
        envp_ptrs.push(e.ptr as usize)
    }

    const prog: &u8 = self.__args[0].ptr

    let cwd_ptr: &u8? = null
    let has_cwd: i32 = 0
    if self.__has_cwd {
        self.__cwd match {
            Some(c) => {
                cwd_ptr = c.ptr
                has_cwd = 1
            },
            None => {},
        }
    }

    let handle: usize = 0
    let in_fd: i32 = -1
    let out_fd: i32 = -1
    let err_fd: i32 = -1
    let err_code: i32 = 0

    const status = __flang_proc_spawn(
        prog,
        argv_ptrs.ptr, argv_ptrs.len,
        envp_ptrs.ptr, envp_ptrs.len,
        cwd_ptr, has_cwd,
        self.__stdin, self.__stdout, self.__stderr,
        &handle,
        &in_fd, &out_fd, &err_fd,
        &err_code,
    )
    if status != 0 {
        return Err(err_code as ProcessError)
    }

    return Ok(.{
        __handle = handle,
        __stdin_fd = in_fd,
        __stdout_fd = out_fd,
        __stderr_fd = err_fd,
        __finished = false,
        __exit_code = 0,
    })
}

// =============================================================================
// Child handle
// =============================================================================

// Block until the child exits. Returns the exit code.
pub fn wait(self: &Child) Result(i32, ProcessError) {
    if self.__finished {
        return Ok(self.__exit_code)
    }
    // Close any inherited write-end of stdin to let the child observe EOF.
    if self.__stdin_fd >= 0 {
        __flang_proc_close_fd(self.__stdin_fd)
        self.__stdin_fd = -1
    }
    let exit: i32 = 0
    let err: i32 = 0
    const status = __flang_proc_wait(self.__handle, &exit, &err)
    if status != 0 {
        return Err(err as ProcessError)
    }
    self.__finished = true
    self.__exit_code = exit
    return Ok(exit)
}

// Terminate the child. Does not wait — call wait() to reap.
pub fn kill(self: &Child) Result((), ProcessError) {
    let err: i32 = 0
    const status = __flang_proc_kill(self.__handle, &err)
    if status != 0 {
        return Err(err as ProcessError)
    }
    return Ok(())
}

pub fn deinit(self: &Child) {
    if self.__stdin_fd >= 0 {
        __flang_proc_close_fd(self.__stdin_fd)
        self.__stdin_fd = -1
    }
    if self.__stdout_fd >= 0 {
        __flang_proc_close_fd(self.__stdout_fd)
        self.__stdout_fd = -1
    }
    if self.__stderr_fd >= 0 {
        __flang_proc_close_fd(self.__stderr_fd)
        self.__stderr_fd = -1
    }
    if !self.__finished {
        // Reap any zombie state silently.
        let exit: i32 = 0
        let err: i32 = 0
        const _s = __flang_proc_wait(self.__handle, &exit, &err)
    }
    __flang_proc_release(self.__handle)
}

// Returns the child's stdout stream if it was configured with Stdio.Pipe,
// otherwise null. Reading transfers ownership of the fd to the returned
// handle; subsequent calls return null.
pub fn stdout(self: &Child) ChildStdout? {
    if self.__stdout_fd < 0 { return null }
    const s = ChildStdout { __fd = self.__stdout_fd }
    self.__stdout_fd = -1
    return s
}

pub fn stderr(self: &Child) ChildStderr? {
    if self.__stderr_fd < 0 { return null }
    const s = ChildStderr { __fd = self.__stderr_fd }
    self.__stderr_fd = -1
    return s
}

pub fn stdin(self: &Child) ChildStdin? {
    if self.__stdin_fd < 0 { return null }
    const s = ChildStdin { __fd = self.__stdin_fd }
    self.__stdin_fd = -1
    return s
}

// =============================================================================
// Reader / Writer impls for the captured streams
// =============================================================================

fn read(self: &ChildStdout, buf: u8[]) usize {
    if self.__fd < 0 { return 0 }
    const n = __flang_proc_read(self.__fd, buf.ptr, buf.len)
    if n < 0 { return 0 }
    return n as usize
}

fn read(self: &ChildStderr, buf: u8[]) usize {
    if self.__fd < 0 { return 0 }
    const n = __flang_proc_read(self.__fd, buf.ptr, buf.len)
    if n < 0 { return 0 }
    return n as usize
}

fn write(self: &ChildStdin, data: u8[]) usize {
    if self.__fd < 0 { return 0 }
    const n = __flang_proc_write(self.__fd, data.ptr, data.len)
    if n < 0 { return 0 }
    return n as usize
}

#implement(ChildStdout, Reader)
#implement(ChildStderr, Reader)
#implement(ChildStdin, Writer)

pub fn close(self: &ChildStdout) {
    if self.__fd >= 0 {
        __flang_proc_close_fd(self.__fd)
        self.__fd = -1
    }
}

pub fn close(self: &ChildStderr) {
    if self.__fd >= 0 {
        __flang_proc_close_fd(self.__fd)
        self.__fd = -1
    }
}

pub fn close(self: &ChildStdin) {
    if self.__fd >= 0 {
        __flang_proc_close_fd(self.__fd)
        self.__fd = -1
    }
}

// Read everything from `s` until EOF into a fresh OwnedString.
pub fn read_to_end(self: &ChildStdout, allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(4096, allocator)
    let buf = [0u8; 4096]
    loop {
        const n = self.read(buf as u8[])
        if n == 0 { break }
        sb.append_bytes(buf[0..n])
    }
    return sb.to_string()
}

pub fn read_to_end(self: &ChildStderr, allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(4096, allocator)
    let buf = [0u8; 4096]
    loop {
        const n = self.read(buf as u8[])
        if n == 0 { break }
        sb.append_bytes(buf[0..n])
    }
    return sb.to_string()
}
