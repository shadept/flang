// std.io.fs — portable filesystem operations.
//
// Directory listing is iterator-based and zero-alloc per entry: the iterator
// owns a 256-byte name buffer and yields `DirEntry` whose `name` is a String
// view into that buffer. The view is invalidated on the next `next()` call.
// Ownership is explicit — callers clone into an OwnedString if they need to
// accumulate entries.
//
//     let it = read_dir(".").unwrap()
//     defer it.deinit()
//     for entry in it {
//         println(entry.name)  // valid only until next iteration
//     }
//     const e = it.err()
//     if e.has_value { eprintln("read failed") }
//
// "." and ".." are filtered at the syscall layer — callers never see them.
//
// Platform errors (POSIX errno, Win32 GetLastError) are translated into
// FsError discriminants directly inside the C shim. Status and error values
// are carried separately, so the i32 out_err parameter can be cast to
// FsError with no translation table.

import std.option
import std.result
import std.string

// =============================================================================
// Types
// =============================================================================

pub type FileKind = enum {
    File
    Dir
    Symlink
    Other
}

pub type DirEntry = struct {
    name: String
    kind: FileKind
}

// Order matters: these tag values are wired into fs.c (FS_* constants).
// Changing the order or inserting a variant requires matching edits there.
pub type FsError = enum {
    NotFound
    PermissionDenied
    NotADirectory
    NameTooLong
    NotSupported
    InvalidArgument
    IOError
}

const NAME_BUF_CAP: usize = 256

// Return-code conventions shared with fs.c.
const R_OK: i32 = 0
const R_EOF: i32 = 1
const R_ERR: i32 = 2

pub type DirIter = struct {
    handle: usize
    name_buf: [u8; 256]
    current_name_len: usize
    current_kind: i32
    last_error: FsError?
    done: bool
}

// =============================================================================
// Foreigns (defined in fs.c)
// =============================================================================

#foreign fn __flang_fs_opendir(path: &u8, out_dir: &usize, out_err: &i32) i32
#foreign fn __flang_fs_readdir(dir: usize, name_buf: &u8, cap: usize, out_len: &usize, out_kind: &i32, out_err: &i32) i32
#foreign fn __flang_fs_closedir(dir: usize, out_err: &i32) i32

// =============================================================================
// API
// =============================================================================

pub fn read_dir(path: String) Result(DirIter, FsError) {
    let handle: usize = 0
    let err: i32 = 0
    const status = __flang_fs_opendir(path.ptr, &handle, &err)
    if status != R_OK {
        return Err(err as FsError)
    }
    let it: DirIter
    it.handle = handle
    return Ok(it)
}

pub fn iter(self: &DirIter) DirIter {
    return self.*
}

pub fn next(self: &DirIter) DirEntry? {
    if self.done { return null }
    let err: i32 = 0
    const status = __flang_fs_readdir(
        self.handle,
        self.name_buf.ptr,
        NAME_BUF_CAP,
        &self.current_name_len,
        &self.current_kind,
        &err,
    )
    if status == R_OK {
        return DirEntry {
            name = String { ptr = self.name_buf.ptr, len = self.current_name_len },
            kind = self.current_kind as FileKind,
        }
    }
    self.done = true
    if status == R_ERR {
        self.last_error = err as FsError
    }
    return null
}

pub fn err(self: &DirIter) FsError? {
    return self.last_error
}

pub fn deinit(self: &DirIter) {
    if self.handle != 0 {
        let err: i32 = 0
        __flang_fs_closedir(self.handle, &err)
        self.handle = 0
    }
}
