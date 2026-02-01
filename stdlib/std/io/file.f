import std.io.buffer
import std.result
import std.string_builder

enum FileMode {
    Read,
    Write,
    Append,
}

enum FileEncoding {
    Utf8,
    Ascii,
}

enum FileError {
    IOError,
    NotFound,
    PermissionDenied,
}

struct FileHandle {
    fd: i32  // TODO system dependent
}

struct File {
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
    if (fd == -1) {
        return Result.Err(FileError.IOError)
    }

    let handle = FileHandle { fd = fd }
    const file = File { path = path, mode = mode, encoding = encoding, handle = handle }
    return Result.Ok(file)
}

pub fn close_file(file: &File) Result((), FileError) {
    if (close(file.handle.fd) == -1) {
        return Result.Err(FileError.IOError)
    }
    return Result.Ok(())
}

// Result(OwnedString, FileError)
pub fn read_all(file: &File) Result(String, FileError) {
    let sb: StringBuilder
    let buf = [u8; 4096] as u8[]
    // GAP: we should have a loop stament
    for (_i in 0..4096 as usize) {
        const n = read(file.handle.fd, buf.ptr, buf.len)
        if (n == -1) {
            return Result.Err(FileError.IOError)
        }
        if (n == 0) {
            break
        }
        sb.append_bytes(buf)
    }
    return Result.Ok(sb.to_string())
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

pub fn reader(file: &File, storage: u8[]) BufferedReader {
    const rfn = ReadFn { ctx = &file as &u8, read = file_read }
    return buffered_reader(rfn, storage)
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
