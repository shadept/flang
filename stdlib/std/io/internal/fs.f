// std.io.internal.fs - the OS surface every io module is built on.
//
// This is the only module in std.io that declares `#foreign`. Everything the platform disagrees
// about is settled here and nowhere else:
//
//   - errno / Win32 codes         -> FsError, translated inside fs.c
//   - O_* open flags              -> a portable mode integer, mapped in fs.c
//   - NUL-terminated C strings    -> `with_c_path` copies; callers pass views
//
// Callers hand in ordinary String views. Nothing here requires a caller to have NUL-terminated
// anything, which is the bug this module exists to make unrepresentable.
//
// Nothing here is meant for application code. `std.io.fs`, `std.io.file` and `std.io.dir` are the
// supported surface; they add no foreigns of their own. FLang has no module-private visibility, so
// that boundary is a convention - importing this directly is possible and unsupported.

import std.allocator
import std.io.types
import std.option
import std.owned
import std.result
import std.string
import std.string_builder

// =============================================================================
// Constants
// =============================================================================

// FileKind, FileInfo and FsError live in std.io.types - below this module, so the public io modules
// can name them without importing internals.

// Portable open modes. fs.c maps these to O_* / _O_*, whose numeric values differ between Linux,
// macOS and Windows.
pub const FS_OPEN_READ: i32 = 0
pub const FS_OPEN_WRITE: i32 = 1
pub const FS_OPEN_APPEND: i32 = 2

pub const FS_NAME_BUF_CAP: usize = 256

// Upper bound for a NUL-terminated path handed to the syscall layer. Matches Linux PATH_MAX; macOS
// (1024) and Windows (260, or 32767 for long paths) are both covered by taking the largest.
//
// The buffers below spell 4096 as a literal rather than using this constant: the self-hosted
// backend refuses a body whose array length is a named const (see docs/known-issues.md). Keep the
// two in step.
pub const FS_PATH_BUF_CAP: usize = 4096

// Return-code conventions shared with fs.c, where they are FS_R_* for the same reason they are
// prefixed here: <unistd.h> defines R_OK as 4.
const FS_R_OK: i32 = 0
const FS_R_EOF: i32 = 1
const FS_R_ERR: i32 = 2

// =============================================================================
// Foreigns (defined in fs.c)
// =============================================================================

#foreign fn __flang_fs_opendir(path: &u8, out_dir: &usize, out_err: &i32) i32
#foreign fn __flang_fs_readdir(dir: usize, name_buf: &u8, cap: usize, out_len: &usize,
    out_kind: &i32, out_err: &i32) i32
#foreign fn __flang_fs_closedir(dir: usize, out_err: &i32) i32
#foreign fn __flang_fs_stat(path: &u8, out_kind: &i32, out_size: &u64, out_err: &i32) i32
#foreign fn __flang_fs_mkdir(path: &u8, out_err: &i32) i32
#foreign fn __flang_fs_unlink(path: &u8, out_err: &i32) i32
#foreign fn __flang_fs_rmdir(path: &u8, out_err: &i32) i32
#foreign fn __flang_fs_rename(from: &u8, to: &u8, out_err: &i32) i32
#foreign fn __flang_fs_open(path: &u8, mode: i32, out_fd: &i32, out_err: &i32) i32
#foreign fn __flang_fs_close(fd: i32, out_err: &i32) i32
#foreign fn __flang_fs_read(fd: i32, buf: &u8, len: usize, out_n: &usize, out_err: &i32) i32
#foreign fn __flang_fs_write(fd: i32, buf: &u8, len: usize, out_n: &usize, out_err: &i32) i32
#foreign fn __flang_fs_set_binary(fd: i32) i32
#foreign fn __flang_fs_getcwd(buf: &u8, cap: usize, out_len: &usize, out_err: &i32) i32
#foreign fn __flang_fs_realpath(path: &u8, buf: &u8, cap: usize, out_len: &usize, out_err: &i32) i32
#foreign fn __flang_fs_temp_dir(buf: &u8, cap: usize, out_len: &usize, out_err: &i32) i32

// =============================================================================
// Path marshalling
// =============================================================================

// Copies `path` into `buf` and NUL-terminates it. False if it does not fit.
fn to_c_path(path: String, buf: u8[]) bool {
    if path.len + 1 > FS_PATH_BUF_CAP {
        return false
    }
    let i: usize = 0
    while i < path.len {
        buf[i] = path[i]
        i = i + 1
    }
    buf[path.len] = 0
    return true
}

// Calls `op` with `path` copied into a NUL-terminated stack buffer. Every path-taking syscall goes
// through here, so the copy happens in one place and no entry point can forget it. Generic over
// what `op` produces: the ones that only report success return `()`, the ones that hand back a
// handle, an fd or a stat return that.
fn with_c_path(path: String, op: $F) Result($T, FsError) {
    if path.len == 0 {
        return Err(FsError.InvalidArgument)
    }
    let buf = [0u8; 4096]
    if !to_c_path(path, buf) {
        return Err(FsError.NameTooLong)
    }
    return op(buf.ptr)
}

// Turns the shim's (status, out_err) pair into a Result. Paired with `with_c_path` this is the
// whole calling convention, in two functions.
//
// Every caller writes `err` through an out-pointer in the same expression that reads it:
//
//     check(__flang_fs_open(p, mode, &fd, &err), err)
//
// which reads the value the call just wrote. That is guaranteed, not lucky: FLang evaluates
// operands left to right (docs/spec.md 5.1.1), enforced by the backend rather than inherited from
// C. Regression tests live in tests/harness/eval_order/.
fn check(status: i32, err: i32) Result((), FsError) {
    if status != FS_R_OK {
        return Err(err as FsError)
    }
    return Ok(())
}

// =============================================================================
// Files
// =============================================================================

// `mode` is one of FS_OPEN_READ / FS_OPEN_WRITE / FS_OPEN_APPEND.
pub fn raw_open(path: String, mode: i32) Result(i32, FsError) {
    // The capture (`mode`) is used only in a straight-line expression, and the branch is an `if`
    // rather than `?`: a capture referenced inside a match arm - which is what `?` lowers to -
    // fails to resolve (docs/known-issues.md). Non-capturing lambdas below use `?` freely.
    return with_c_path(path, fn(p: &u8) Result(i32, FsError) {
        let fd: i32 = 0
        let err: i32 = 0
        const r = check(__flang_fs_open(p, mode, &fd, &err), err)
        if r.is_err() {
            return Err(r.unwrap_err())
        }
        return Ok(fd)
    })
}

pub fn raw_close(fd: i32) Result((), FsError) {
    let err: i32 = 0
    return check(__flang_fs_close(fd, &err), err)
}

// Ok(0) means end of file, not an error.
pub fn raw_read(fd: i32, buf: u8[]) Result(usize, FsError) {
    let n: usize = 0
    let err: i32 = 0
    check(__flang_fs_read(fd, buf.ptr, buf.len, &n, &err), err)?
    return Ok(n)
}

// Put an fd into binary mode. Windows CRT opens the standard streams in text mode (reads collapse
// CRLF and stop at ^Z, writes expand \n to \r\n); byte-exact protocols over them need this. On
// POSIX every fd is already binary and this is a no-op. Returns false when the OS refuses.
pub fn raw_set_binary(fd: i32) bool {
    return __flang_fs_set_binary(fd) == 0
}

// A short write is reported honestly; looping is the caller's job.
pub fn raw_write(fd: i32, data: u8[]) Result(usize, FsError) {
    let n: usize = 0
    let err: i32 = 0
    check(__flang_fs_write(fd, data.ptr, data.len, &n, &err), err)?
    return Ok(n)
}

pub fn raw_unlink(path: String) Result((), FsError) {
    return with_c_path(path, fn(p: &u8) Result((), FsError) {
        let err: i32 = 0
        return check(__flang_fs_unlink(p, &err), err)
    })
}

// =============================================================================
// Directories
// =============================================================================

pub fn raw_mkdir(path: String) Result((), FsError) {
    return with_c_path(path, fn(p: &u8) Result((), FsError) {
        let err: i32 = 0
        return check(__flang_fs_mkdir(p, &err), err)
    })
}

pub fn raw_rmdir(path: String) Result((), FsError) {
    return with_c_path(path, fn(p: &u8) Result((), FsError) {
        let err: i32 = 0
        return check(__flang_fs_rmdir(p, &err), err)
    })
}

pub fn raw_opendir(path: String) Result(usize, FsError) {
    return with_c_path(path, fn(p: &u8) Result(usize, FsError) {
        let handle: usize = 0
        let err: i32 = 0
        check(__flang_fs_opendir(p, &handle, &err), err)?
        return Ok(handle)
    })
}

pub fn raw_closedir(handle: usize) Result((), FsError) {
    let err: i32 = 0
    return check(__flang_fs_closedir(handle, &err), err)
}

// An open directory handle plus the buffer its entries are read into.
//
// This lives in internal rather than in std.io.dir because two public modules need it: `Dir` wraps
// one, and `walk_dir` holds a stack of them. Routing the walk through std.io.dir instead would make
// fs and dir mutually dependent.
//
// `name` on a yielded entry is a view into `name_buf` and dies on the next `next()` call. Callers
// that accumulate entries must clone.
pub type RawDirEntry = struct {
    name: String
    kind: FileKind
}

pub type RawDir = struct {
    handle: usize
    name_buf: [u8; 256]
    current_name_len: usize
    current_kind: i32
    last_error: FsError?
    done: bool
}

pub fn raw_dir_open(path: String) Result(RawDir, FsError) {
    const handle = raw_opendir(path)?
    let d: RawDir
    d.handle = handle
    d.current_name_len = 0
    d.current_kind = 0
    d.last_error = null
    d.done = false
    return Ok(d)
}

pub fn iter(self: &RawDir) &RawDir {
    // Returning `&self` (not a copy) means `for entry in d { ... }` mutates the original, so
    // `d.err()` stays meaningful after the loop.
    return self
}

pub fn next(self: &RawDir) RawDirEntry? {
    if self.done {
        return null
    }
    let err: i32 = 0
    const status = __flang_fs_readdir(self.handle, self.name_buf.ptr, FS_NAME_BUF_CAP,
        &self.current_name_len, &self.current_kind, &err)
    if status == FS_R_OK {
        return Some(RawDirEntry {
            name = from_c_string(self.name_buf.ptr, Some(self.current_name_len)),
            kind = self.current_kind as FileKind,
        })
    }
    self.done = true
    if status == FS_R_ERR {
        self.last_error = Some(err as FsError)
    }
    return null
}

pub fn err(self: &RawDir) FsError? {
    return self.last_error
}

pub fn deinit(self: &RawDir) {
    if self.handle != 0 {
        const _closed = raw_closedir(self.handle)
        self.handle = 0
    }
}

// =============================================================================
// Path-level queries
// =============================================================================

// Follows symlinks - the reported kind is the target's, not the link's.
pub fn raw_stat(path: String) Result(FileInfo, FsError) {
    return with_c_path(path, fn(p: &u8) Result(FileInfo, FsError) {
        let kind: i32 = 0
        let size: u64 = 0
        let err: i32 = 0
        check(__flang_fs_stat(p, &kind, &size, &err), err)?
        return Ok(FileInfo { kind = kind as FileKind, size = size })
    })
}

// Replaces `to` when it exists, on every platform - the Windows shim uses MoveFileEx rather than
// the CRT rename, which refuses an existing target.
pub fn raw_rename(from: String, to: String) Result((), FsError) {
    // Two paths, so two nested copies - the inner lambda captures the outer's buffer pointer.
    return with_c_path(from, fn(f: &u8) Result((), FsError) {
        return with_c_path(to, fn(t: &u8) Result((), FsError) {
            let err: i32 = 0
            return check(__flang_fs_rename(f, t, &err), err)
        })
    })
}

pub fn raw_getcwd(allocator: &Allocator? = null) Result(OwnedString, FsError) {
    let buf = [0u8; 4096]
    let out_len: usize = 0
    let err: i32 = 0
    check(__flang_fs_getcwd(buf.ptr, FS_PATH_BUF_CAP, &out_len, &err), err)?
    return Ok(from_view(from_c_string(buf.ptr, Some(out_len)), allocator))
}

pub fn raw_temp_dir(allocator: &Allocator? = null) Result(OwnedString, FsError) {
    let buf = [0u8; 4096]
    let out_len: usize = 0
    let err: i32 = 0
    check(__flang_fs_temp_dir(buf.ptr, FS_PATH_BUF_CAP, &out_len, &err), err)?
    return Ok(from_view(from_c_string(buf.ptr, Some(out_len)), allocator))
}

// Resolves symlinks and `..`, and requires the target to exist.
pub fn raw_realpath(path: String, allocator: &Allocator? = null) Result(OwnedString, FsError) {
    // `buf.len` rather than FS_PATH_BUF_CAP, and an `if` rather than `?`: a lambda can reference
    // neither a module-level const nor a capture inside a match arm (docs/known-issues.md).
    // `allocator` is captured, so it is only named in a straight-line expression.
    return with_c_path(path, fn(p: &u8) Result(OwnedString, FsError) {
        let buf = [0u8; 4096]
        let out_len: usize = 0
        let err: i32 = 0
        const r = check(__flang_fs_realpath(p, buf.ptr, buf.len, &out_len, &err), err)
        if r.is_err() {
            return Err(r.unwrap_err())
        }
        return Ok(from_view(from_c_string(buf.ptr, Some(out_len)), allocator))
    })
}
