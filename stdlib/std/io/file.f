import std.io.reader
import std.io.writer
import std.allocator
import std.result
import std.string
import std.string_builder

pub type FileMode = enum {
    Read,
    Write,
    Append,
}

pub type FileEncoding = enum {
    Utf8,
    Ascii,
}

pub type FileError = enum {
    IOError,
    NotFound,
    PermissionDenied,
}

pub type FileHandle = struct {
    fd: i32  // TODO system dependent
}

pub type File = struct {
    path: String
    mode: FileMode
    encoding: FileEncoding
    handle: FileHandle
}

pub fn open_file(path: String, mode: FileMode) Result(File, FileError) {
    return open_file(path, mode, FileEncoding.Utf8)
}

pub fn open_file(path: String, mode: FileMode, encoding: FileEncoding) Result(File, FileError) {
    let flags = mode match {
        FileMode.Read => O_RDONLY,
        FileMode.Write => O_WRONLY + O_CREAT + O_TRUNC,
        FileMode.Append => O_WRONLY + O_CREAT + O_APPEND,
    }
    const fd = open(path.ptr, flags)
    if fd == -1 {
        return Err(FileError.IOError)
    }

    let handle = FileHandle { fd = fd }
    const file = File { path = path, mode = mode, encoding = encoding, handle = handle }
    return Ok(file)
}

pub fn close_file(file: &File) Result((), FileError) {
    if close(file.handle.fd) == -1 {
        return Err(FileError.IOError)
    }
    return Ok(())
}

pub fn read_all(file: &File, allocator: &Allocator? = null) Result(OwnedString, FileError) {
    const PAGE_SIZE = 4096
    let sb = string_builder(PAGE_SIZE, allocator)
    loop {
        const buf = sb.ptr + sb.len
        const len = sb.cap - sb.len
        const n = read(file.handle.fd, buf, len)
        if n < 0 {
            return Err(FileError.IOError)
        }
        sb.len = n as usize // XXX: this will not be possible after we implement scoped mutability
        if n as usize < len {
            break
        }
        // Grow capacity by one page. StringBuilder doubles capacity on each growth,
        // so subsequent calls over-allocate. This amortizes allocation cost and aligns
        // with typical file size distributions (many small, few large).
        sb.ensure_capacity(sb.cap + PAGE_SIZE)
    }
    return Ok(sb.to_string())
}


pub fn read_all_inplace(file: &File, allocator: &Allocator) Result(OwnedString, FileError) {
    const PAGE_SIZE = 4096
    let sb = string_builder(PAGE_SIZE, allocator)
    let buf = [0u8; PAGE_SIZE]
    loop {
        const n = read(file.handle.fd, buf.ptr, buf.len)
        if n == -1 {
            return Err(FileError.IOError)
        }
        const buf_slice = buf as u8[]
        const n = n as usize
        sb.append_bytes(buf_slice[..n])
        if n as usize < PAGE_SIZE {
            break
        }
    }
    return Ok(sb.to_string())
}

pub fn write(file: &File, value: String) Result((), FileError) {
    // TODO handle encoding
    let bytes = value.as_raw_bytes()
    let total_written = 0usize
    loop {
        const n = write(file.handle.fd, bytes[total_written..bytes.len].ptr, bytes.len - total_written)
        if (n == -1) {
            return Err(FileError.IOError)
        }
        total_written = total_written + n as usize
        if (total_written >= bytes.len) {
            break
        }
    }
    return Ok(())
}

// =============================================================================
// Reader
// =============================================================================

fn file_read(ctx: &u8, buf: u8[]) usize {
    // Read from the file handle
    const file = ctx as &File
    const bytes = read(file.handle.fd, buf.ptr, buf.len)
    if (bytes == -1) {
        return 0
    }
    return bytes as usize
}

pub fn reader(file: &File, storage: u8[]) Reader {
    const rfn = ReadFn { ctx = &file as &u8, read = file_read }
    return reader(rfn, storage)
}

// =============================================================================
// Writer
// =============================================================================

fn file_write(ctx: &u8, data: u8[]) usize {
    const file = ctx as &File
    const n = write(file.handle.fd, data.ptr, data.len)
    if (n == -1) {
        return 0
    }
    return n as usize
}

pub fn writer(file: &File, storage: u8[]) Writer {
    const wfn = WriteFn { ctx = &file as &u8, write = file_write }
    return writer(wfn, storage)
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
// Foreigns
// =============================================================================

// linux specific
const O_RDONLY: i32 = 0
const O_WRONLY: i32 = 1
const O_CREAT: i32 = 64
const O_TRUNC: i32 = 512
const O_APPEND: i32 = 1024

#foreign fn open(path: &u8, flags: i32) i32
#foreign fn close(fd: i32) i32

#foreign fn read(fd: i32, buf: &u8, len: usize) isize
#foreign fn write(fd: i32, buf: &u8, len: usize) isize
