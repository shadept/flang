// std.io.file - an open file and the operations that need one.
//
// Sits on std.io.internal.fs, which owns every syscall. This module holds a File and reports
// `FileError`: the set of things that can go wrong when the thing you named is meant to be a file.
// Directory-shaped failures (NotEmpty, NotADirectory) are not in it, by construction.
//
// Paths are ordinary String views. Nothing here requires NUL termination - internal copies before
// it reaches the OS.

import std.io.reader
import std.io.writer
import std.allocator
import std.option
import std.owned
import std.result
import std.string
import std.string_builder
import std.test
import std.io.internal.fs
import std.io.types

pub type FileMode = enum {
    Read
    Write
    Append
}

pub type FileEncoding = enum {
    Utf8
    Ascii
}

// Order is load-bearing for existing callers: IOError stays tag 0.
pub type FileError = enum {
    IOError
    NotFound
    PermissionDenied
    AlreadyExists
    NameTooLong
    InvalidArgument
}

pub type FileHandle = struct {
    fd: i32
}

pub type File = struct {
    path: String
    mode: FileMode
    encoding: FileEncoding
    handle: FileHandle
}

// =============================================================================
// Error translation
// =============================================================================

// The OS speaks FsError; this module speaks FileError. This is the only place the two meet, so a
// new errno mapping is added once, in fs.c, and lands here automatically.
//
// NotADirectory and NotEmpty cannot describe a file operation - a caller that hit one asked for
// something structurally impossible, which is IOError's job.
fn to_file_error(e: FsError) FileError {
    return e match {
        NotFound => FileError.NotFound
        PermissionDenied => FileError.PermissionDenied
        AlreadyExists => FileError.AlreadyExists
        NameTooLong => FileError.NameTooLong
        InvalidArgument => FileError.InvalidArgument
        _ => FileError.IOError
    }
}

fn open_mode(mode: FileMode) i32 {
    // The numeric O_* values differ between Linux, macOS and Windows; fs.c resolves them. This is a
    // portable selector, not a flag set.
    return mode match {
        Read => FS_OPEN_READ
        Write => FS_OPEN_WRITE
        Append => FS_OPEN_APPEND
    }
}

// =============================================================================
// Open / close
// =============================================================================

pub fn open_file(path: String, mode: FileMode) Result(File, FileError) {
    return open_file(path, mode, FileEncoding.Utf8)
}

pub fn open_file(path: String, mode: FileMode, encoding: FileEncoding) Result(File, FileError) {
    const fd = raw_open(path, open_mode(mode)).map_err(to_file_error)?
    return Ok(File {
        path = path,
        mode = mode,
        encoding = encoding,
        handle = FileHandle { fd = fd },
    })
}

pub fn close_file(file: &File) Result((), FileError) {
    return raw_close(file.handle.fd).map_err(to_file_error)
}

// Deletes a file, or a symlink itself - never the symlink's target. A directory is rejected by the
// OS; use `remove_dir` from std.io.dir.
pub fn remove_file(path: String) Result((), FileError) {
    return raw_unlink(path).map_err(to_file_error)
}

// =============================================================================
// Bulk read / write
// =============================================================================

pub fn read_all(file: &File, allocator: &Allocator? = null) Result(OwnedString, FileError) {
    const PAGE_SIZE = 4096
    // Owned so a mid-read failure frees the builder on the way out: `?` bails straight past the
    // return, and the defer is what catches it.
    let sb = owned(string_builder(PAGE_SIZE, allocator))
    defer sb.deinit()
    loop {
        const tail = sb.unwritten_buf()
        const n = raw_read(file.handle.fd, tail).map_err(to_file_error)?
        sb.commit(n)
        if n < tail.len {
            break
        }
        // Grow capacity by one page. StringBuilder doubles capacity on each growth, so subsequent
        // calls over-allocate. This amortizes allocation cost and aligns with typical file size
        // distributions (many small, few large).
        sb.ensure_capacity(sb.cap + PAGE_SIZE)
    }
    return Ok(sb.transfer().to_string())
}

pub fn read_all_inplace(file: &File, allocator: &Allocator) Result(OwnedString, FileError) {
    const PAGE_SIZE = 4096
    let sb = owned(string_builder(PAGE_SIZE, Some(allocator)))
    defer sb.deinit()
    let buf = [0u8; 4096]
    loop {
        const buf_slice = buf as u8[]
        const n = raw_read(file.handle.fd, buf_slice).map_err(to_file_error)?
        sb.append_bytes(buf_slice[..n])
        if n < PAGE_SIZE {
            break
        }
    }
    return Ok(sb.transfer().to_string())
}

pub fn write(file: &File, value: String) Result((), FileError) {
    // TODO handle encoding
    let bytes = value.as_raw_bytes()
    let total_written = 0usize
    loop {
        if total_written >= bytes.len {
            break
        }
        const n = raw_write(file.handle.fd, bytes[total_written..bytes.len])
            .map_err(to_file_error)?
        // A zero-length write with bytes still pending would spin forever.
        if n == 0 {
            return Err(FileError.IOError)
        }
        total_written = total_written + n
    }
    return Ok(())
}

// =============================================================================
// Reader / Writer interface implementations
// =============================================================================

fn read(self: &File, buf: u8[]) usize {
    return raw_read(self.handle.fd, buf).unwrap_or(0)
}

fn write(self: &File, data: u8[]) usize {
    return raw_write(self.handle.fd, data).unwrap_or(0)
}

#implement(File, Reader)
#implement(File, Writer)

pub fn buffered_reader(file: &File, storage: u8[]) BufferedReader {
    return buffered_reader(file.reader(), storage)
}

pub fn buffered_writer(file: &File, storage: u8[]) BufferedWriter {
    return buffered_writer(file.writer(), storage)
}

// Put the file's descriptor into binary mode. Files opened by `open_file` already are; the standard
// streams inherit the platform default, which on Windows is text mode - reads collapse CRLF and
// stop at ^Z, writes expand \n to \r\n. A byte-exact protocol over stdin/stdout (the LSP's
// Content-Length framing) must switch them first. No-op on POSIX. Returns false when the OS
// refuses.
pub fn set_binary_mode(file: &File) bool {
    return raw_set_binary(file.handle.fd)
}

// =============================================================================
// Standard streams (stdin/stdout/stderr as Files)
// =============================================================================

pub const stdin = File {
    path = "<stdin>",
    mode = FileMode.Read,
    encoding = FileEncoding.Utf8,
    handle = FileHandle { fd = 0 },
}

pub const stdout = File {
    path = "<stdout>",
    mode = FileMode.Write,
    encoding = FileEncoding.Utf8,
    handle = FileHandle { fd = 1 },
}

pub const stderr = File {
    path = "<stderr>",
    mode = FileMode.Write,
    encoding = FileEncoding.Utf8,
    handle = FileHandle { fd = 2 },
}

// =============================================================================
// Tests
// =============================================================================

test "open_file on a missing path reports NotFound, not IOError" {
    const r = open_file("definitely_not_here.txt", FileMode.Read)
    assert_true(r.is_err(), "open fails")
    assert_true(r.unwrap_err() match { NotFound => true, _ => false }, "errno reaches the caller")
}

test "write, read back, and remove a file" {
    const p = "build/file_test.tmp"

    const opened = open_file(p, FileMode.Write)
    assert_true(opened.is_ok(), "open for write")
    let w = opened.unwrap()
    assert_true(write(&w, "hello flang").is_ok(), "write")
    assert_true(close_file(&w).is_ok(), "close after write")

    const reopened = open_file(p, FileMode.Read)
    assert_true(reopened.is_ok(), "open for read")
    let r = reopened.unwrap()
    const text = read_all(&r)
    assert_true(text.is_ok(), "read_all")
    let owned_text = text.unwrap()
    assert_eq(owned_text.as_view(), "hello flang", "round-trip")
    owned_text.deinit()
    assert_true(close_file(&r).is_ok(), "close after read")

    assert_true(remove_file(p).is_ok(), "remove")
    assert_true(remove_file(p).is_err(), "second remove fails")
}

test "write truncates an existing file" {
    const p = "build/file_test_trunc.tmp"

    let a = open_file(p, FileMode.Write).unwrap()
    assert_true(write(&a, "long original contents").is_ok(), "first write")
    assert_true(close_file(&a).is_ok(), "close")

    let b = open_file(p, FileMode.Write).unwrap()
    assert_true(write(&b, "short").is_ok(), "second write")
    assert_true(close_file(&b).is_ok(), "close")

    let c = open_file(p, FileMode.Read).unwrap()
    const text = read_all(&c).unwrap()
    assert_eq(text.as_view(), "short", "old tail is gone")
    text.deinit()
    assert_true(close_file(&c).is_ok(), "close")
    assert_true(remove_file(p).is_ok(), "cleanup")
}

test "append adds to the end instead of truncating" {
    const p = "build/file_test_append.tmp"

    let a = open_file(p, FileMode.Write).unwrap()
    assert_true(write(&a, "one").is_ok(), "write")
    assert_true(close_file(&a).is_ok(), "close")

    let b = open_file(p, FileMode.Append).unwrap()
    assert_true(write(&b, "-two").is_ok(), "append")
    assert_true(close_file(&b).is_ok(), "close")

    let c = open_file(p, FileMode.Read).unwrap()
    const text = read_all(&c).unwrap()
    assert_eq(text.as_view(), "one-two", "appended")
    text.deinit()
    assert_true(close_file(&c).is_ok(), "close")
    assert_true(remove_file(p).is_ok(), "cleanup")
}
