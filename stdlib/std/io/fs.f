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
import std.string_builder
import std.list
import std.allocator

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

pub type FileInfo = struct {
    kind: FileKind
    size: u64
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
#foreign fn __flang_fs_stat(path: &u8, out_kind: &i32, out_size: &u64, out_err: &i32) i32

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

// =============================================================================
// Stat + convenience queries
// =============================================================================

// Fetches metadata for `path`. Follows symlinks — the reported kind is the
// target's kind, not the link's.
pub fn stat(path: String) Result(FileInfo, FsError) {
    let kind: i32 = 0
    let size: u64 = 0
    let err: i32 = 0
    const status = __flang_fs_stat(path.ptr, &kind, &size, &err)
    if status != R_OK {
        return Err(err as FsError)
    }
    return Ok(FileInfo {
        kind = kind as FileKind,
        size = size,
    })
}

// Returns true iff `path` refers to an existing entry. Follows symlinks.
pub fn exists(path: String) bool {
    return stat(path).is_ok()
}

// Returns true iff `path` exists and is a directory. Follows symlinks.
pub fn is_dir(path: String) bool {
    const r = stat(path)
    r match {
        Ok(info) => info.kind match {
            Dir => true,
            _ => false,
        },
        Err(_) => false,
    }
}

// Returns true iff `path` exists and is a regular file. Follows symlinks.
pub fn is_file(path: String) bool {
    const r = stat(path)
    r match {
        Ok(info) => info.kind match {
            File => true,
            _ => false,
        },
        Err(_) => false,
    }
}

// =============================================================================
// Recursive walk — WalkIter
// =============================================================================
//
// DFS walk, built on top of DirIter. Yields each entry (including dirs) in
// pre-order. `path` is a String view into the iterator's path builder and is
// invalidated on the next `next()` call, just like DirEntry.name.
//
// Symlinks are NOT followed (to avoid infinite loops on cyclic trees). They
// are yielded as Symlink entries with no descent.
//
//     let w = walk_dir("src").unwrap()
//     defer w.deinit()
//     for entry in w {
//         println(entry.path)
//     }
//     if let e = w.err() { eprintln("walk failed") }

pub type WalkEntry = struct {
    path: String
    kind: FileKind
    depth: usize
}

type WalkFrame = struct {
    dir: DirIter
    path_len_before: usize   // length of path_buf before this frame's segment
}

pub type WalkIter = struct {
    stack: List(WalkFrame)
    path_buf: StringBuilder
    last_error: FsError?
    done: bool
}

pub fn walk_dir(root: String, allocator: &Allocator? = null) Result(WalkIter, FsError) {
    const root_iter_r = read_dir(root)
    if root_iter_r.is_err() {
        return Err(root_iter_r.unwrap_err())
    }

    let sb = string_builder(root.len + 64, allocator)
    sb.append(root)
    // Strip a trailing separator so we always append "/" before segment names.
    if sb.len > 0 {
        const last: &u8 = sb.ptr + (sb.len - 1)
        if last.* == '/' or last.* == '\\' {
            sb.len = sb.len - 1
        }
    }
    const root_len = sb.len

    let stack: List(WalkFrame) = list(8, allocator)
    stack.push(WalkFrame {
        dir = root_iter_r.unwrap(),
        path_len_before = root_len,
    })

    let w: WalkIter
    w.stack = stack
    w.path_buf = sb
    w.last_error = null
    w.done = false
    return Ok(w)
}

pub fn iter(self: &WalkIter) &WalkIter {
    return self
}

pub fn next(self: &WalkIter) WalkEntry? {
    if self.done { return null }

    loop {
        if self.stack.len == 0 {
            self.done = true
            return null
        }

        // Borrow the top frame in place — we need to mutate its DirIter.
        const top: &WalkFrame = self.stack[self.stack.len - 1]

        const entry_opt = top.dir.next()
        if entry_opt.has_value == false {
            // DirIter exhausted (or errored). Capture its error if any.
            if top.dir.last_error.has_value and self.last_error.has_value == false {
                self.last_error = top.dir.last_error
            }
            // Restore path_buf to this frame's prefix, then pop.
            self.path_buf.len = top.path_len_before
            top.dir.deinit()
            const _popped = self.stack.pop()
            continue
        }

        const entry = entry_opt.value

        // Reset builder to this frame's base, then append "/<name>".
        self.path_buf.len = top.path_len_before
        if self.path_buf.len > 0 {
            self.path_buf.append('/')
        }
        self.path_buf.append_bytes(entry.name.as_raw_bytes())
        const depth = self.stack.len - 1

        const path_view = self.path_buf.as_view()
        const result = WalkEntry {
            path = path_view,
            kind = entry.kind,
            depth = depth,
        }

        // Descend into directories (not symlinks — avoid cycles).
        if is_kind_dir(entry.kind) {
            // NUL-terminate the path for the syscall without bumping len.
            self.path_buf.ensure_capacity(self.path_buf.len + 1)
            const term: &u8 = self.path_buf.ptr + self.path_buf.len
            term.* = 0
            const child_r = read_dir(path_view)
            if child_r.is_ok() {
                self.stack.push(WalkFrame {
                    dir = child_r.unwrap(),
                    path_len_before = self.path_buf.len,
                })
            } else if self.last_error.has_value == false {
                self.last_error = child_r.unwrap_err()
            }
        }

        return result
    }
    // Unreachable
    return null
}

pub fn err(self: &WalkIter) FsError? {
    return self.last_error
}

pub fn deinit(self: &WalkIter) {
    loop {
        if self.stack.len == 0 { break }
        const top: &WalkFrame = self.stack[self.stack.len - 1]
        top.dir.deinit()
        const _popped = self.stack.pop()
    }
    self.stack.deinit()
    self.path_buf.deinit()
}

fn is_kind_dir(k: FileKind) bool {
    k match {
        Dir => true,
        _ => false,
    }
}

// =============================================================================
// Glob — built on top of walk_dir
// =============================================================================
//
// Supported pattern syntax:
//   *   matches any run of non-separator bytes within a single path segment
//   ?   matches a single non-separator byte
//   **  matches any number of path segments (including zero)
//   /   segment separator (on any platform — the shim normalizes internally)
//
// Character classes ([abc], [a-z], [!abc]) are not supported yet.
//
//     let it = glob("src/**/*.f").unwrap()
//     defer it.deinit()
//     for path in it { println(path) }
//     if let e = it.err() { eprintln("glob failed") }

pub type GlobIter = struct {
    walk: WalkIter
    pattern: StringBuilder   // owns pattern bytes; view into this for matching
    done: bool
}

pub fn glob(pattern: String, allocator: &Allocator? = null) Result(GlobIter, FsError) {
    const prefix_end = find_glob_prefix_end(pattern)

    // Choose walk root. If there's no literal prefix at all, walk ".".
    let root_str: String = "."
    if prefix_end > 0 {
        root_str = String { ptr = pattern.ptr, len = prefix_end }
    }

    let pat_buf = string_builder(pattern.len + 1, allocator)
    pat_buf.append(pattern)

    // Build a NUL-terminated root path for read_dir.
    let root_buf = string_builder(root_str.len + 1, allocator)
    root_buf.append(root_str)
    root_buf.ensure_capacity(root_buf.len + 1)
    const term: &u8 = root_buf.ptr + root_buf.len
    term.* = 0

    const w_r = walk_dir(root_buf.as_view(), allocator)
    root_buf.deinit()
    if w_r.is_err() {
        pat_buf.deinit()
        return Err(w_r.unwrap_err())
    }

    let g: GlobIter
    g.walk = w_r.unwrap()
    g.pattern = pat_buf
    g.done = false
    return Ok(g)
}

pub fn iter(self: &GlobIter) &GlobIter {
    return self
}

pub fn next(self: &GlobIter) String? {
    if self.done { return null }
    const pat_full = self.pattern.as_view()
    loop {
        const entry_opt = self.walk.next()
        if entry_opt.has_value == false {
            self.done = true
            return null
        }
        const entry = entry_opt.value
        if match_glob(pat_full, entry.path) {
            return entry.path
        }
    }
    return null
}

pub fn err(self: &GlobIter) FsError? {
    return self.walk.err()
}

pub fn deinit(self: &GlobIter) {
    self.walk.deinit()
    self.pattern.deinit()
}

// Returns the index of the first glob metacharacter, backed up to the last
// preceding '/'. Used to split a pattern into a literal walk root and a
// glob-matched tail. Returns the full pattern length when there are no
// metacharacters.
fn find_glob_prefix_end(pattern: String) usize {
    let first_meta: usize = pattern.len
    for i in 0..pattern.len {
        const b = pattern[i]
        if b == '*' or b == '?' or b == '[' {
            first_meta = i
            break
        }
    }
    if first_meta == pattern.len {
        return pattern.len
    }
    // Back up to last '/' before the metachar.
    let end: usize = 0
    for i in 0..first_meta {
        if pattern[i] == '/' {
            end = i
        }
    }
    return end
}

// Matches `path` against `pattern` with glob semantics. Both arguments are
// treated as '/'-separated. `**` crosses segment boundaries; `*` and `?` do
// not.
pub fn match_glob(pattern: String, path: String) bool {
    return match_rec(pattern, 0, path, 0)
}

fn match_rec(pattern: String, p: usize, path: String, t: usize) bool {
    loop {
        if p >= pattern.len {
            return t >= path.len
        }
        const pc = pattern[p]

        // Handle '**' (with optional trailing '/').
        if pc == '*' and p + 1 < pattern.len and pattern[p + 1] == '*' {
            let rest_p = p + 2
            if rest_p < pattern.len and pattern[rest_p] == '/' {
                rest_p = rest_p + 1
            }
            // '**' matches zero or more segments. Try each cut point in path.
            let i: usize = t
            loop {
                if match_rec(pattern, rest_p, path, i) { return true }
                if i >= path.len { return false }
                // Advance to end of current segment, then past the slash.
                loop {
                    if i >= path.len { break }
                    if path[i] == '/' { break }
                    i = i + 1
                }
                if i < path.len { i = i + 1 }
            }
        }

        if pc == '*' {
            // '*' matches zero or more non-separator bytes in the current segment.
            let i: usize = t
            loop {
                if match_rec(pattern, p + 1, path, i) { return true }
                if i >= path.len { return false }
                if path[i] == '/' { return false }
                i = i + 1
            }
        }

        if t >= path.len { return false }
        const tc = path[t]

        if pc == '?' {
            if tc == '/' { return false }
            p = p + 1
            t = t + 1
            continue
        }

        if pc != tc { return false }
        p = p + 1
        t = t + 1
    }
    return false
}
