// std.io.fs - filesystem operations that do not hold anything open.
//
// The three io modules split by what you hold:
//
//   std.io.fs    a path        stat, exists, rename, walk_dir, glob, cwd
//   std.io.file  an open File  open/read/write/close, remove_file
//   std.io.dir   an open Dir   entries, create_dir, remove_dir
//
// All three sit on std.io.internal.fs, which owns every syscall. This module
// reports `FsError` because its operations are kind-agnostic: `exists` and
// `rename` do not care whether the target is a file or a directory, so a
// narrower error type would have to lie about one of them.
//
// Paths are ordinary String views - nothing here requires NUL termination.

import std.allocator
import std.list
import std.option
import std.owned
import std.path
import std.result
import std.stack
import std.string
import std.string_builder
import std.test
import std.io.internal.fs
import std.io.types

// FileKind, FileInfo and FsError come from std.io.types, which sits below
// every io module. Import it directly if you need qualified access such as
// `FileKind.Dir`; matching on the variant needs no import.

// =============================================================================
// Stat + convenience queries
// =============================================================================

// Fetches metadata for `path`. Follows symlinks - the reported kind is the
// target's kind, not the link's.
pub fn stat(path: String) Result(FileInfo, FsError) {
    return raw_stat(path)
}

// Returns true iff `path` refers to an existing entry. Follows symlinks.
pub fn exists(path: String) bool {
    return raw_stat(path).is_ok()
}

// Returns true iff `path` exists and is a directory. Follows symlinks.
pub fn is_dir(path: String) bool {
    const r = raw_stat(path)
    return r match {
        Ok(info) => is_kind_dir(info.kind),
        Err(_) => false,
    }
}

// Returns true iff `path` exists and is a regular file. Follows symlinks.
pub fn is_file(path: String) bool {
    const r = raw_stat(path)
    return r match {
        Ok(info) => info.kind match {
            File => true,
            _ => false,
        },
        Err(_) => false,
    }
}

// Moves `from` to `to`, replacing `to` if it exists - on every platform.
// Both paths must be on the same filesystem; crossing devices is an OS-level
// error here, not a silent copy. Works on files and directories alike, which
// is why this is an fs operation rather than a file or dir one.
pub fn rename(from: String, to: String) Result((), FsError) {
    return raw_rename(from, to)
}

// =============================================================================
// Process-relative paths
// =============================================================================
//
// These live here rather than in std.path because they read the world through
// something other than their arguments. std.path stays pure string algebra so
// it can be used - and tested - without a filesystem.

// The current working directory of the process.
pub fn cwd(allocator: &Allocator? = null) Result(Path, FsError) {
    const s = raw_getcwd(allocator)?
    defer s.deinit()
    return Ok(path(s.as_view(), allocator))
}

// The directory for temporary files: $TMPDIR (falling back to /tmp) on POSIX,
// GetTempPath on Windows. Never has a trailing separator, so callers can
// always join with one.
pub fn temp_dir(allocator: &Allocator? = null) Result(Path, FsError) {
    const s = raw_temp_dir(allocator)?
    defer s.deinit()
    return Ok(path(s.as_view(), allocator))
}

// An absolute, lexically-normalized form of `p`, joined against cwd() when
// relative. Does NOT resolve symlinks and does not require the path to exist -
// use `canonicalize` when you need either.
pub fn to_absolute(p: &Path, allocator: &Allocator? = null) Result(Path, FsError) {
    if p.is_absolute() {
        return Ok(p.normalize())
    }
    let base = cwd(allocator)?
    defer base.deinit()

    let joined = base.join(p.as_view())
    defer joined.deinit()
    return Ok(joined.normalize())
}

// Resolves symlinks and `..` against the real filesystem. The target must
// exist; NotFound if it does not.
pub fn canonicalize(p: &Path, allocator: &Allocator? = null) Result(Path, FsError) {
    const s = raw_realpath(p.as_view(), allocator)?
    defer s.deinit()
    return Ok(path(s.as_view(), allocator))
}

// =============================================================================
// Recursive walk - WalkIter
// =============================================================================
//
// DFS walk, built on top of RawDir. Yields each entry (including dirs) in
// pre-order. `path` is a String view into the iterator's path builder and is
// invalidated on the next `next()` call, just like a directory entry's name.
//
// Symlinks are NOT followed (to avoid infinite loops on cyclic trees). They
// are yielded as Symlink entries with no descent.
//
//     let w = walk_dir("src").unwrap()
//     defer w.deinit()
//     for entry in w {
//         println(entry.path)
//     }
//     if w.err().is_some() { eprintln("walk failed") }

pub type WalkEntry = struct {
    path: String
    kind: FileKind
    depth: usize
}

type WalkFrame = struct {
    dir: RawDir
    path_len_before: usize   // length of path_buf before this frame's segment
}

pub type WalkIter = struct {
    stack: Stack(WalkFrame)
    path_buf: StringBuilder
    last_error: FsError?
    done: bool
}

pub fn walk_dir(root: String, allocator: &Allocator? = null) Result(WalkIter, FsError) {
    const root_iter = raw_dir_open(root)?

    let sb = string_builder(root.len + 64, allocator)
    sb.append(root)
    // Strip a trailing separator so we always append "/" before segment names.
    if sb.len > 0 {
        const last: &u8 = sb.ptr + (sb.len - 1)
        if last.* == '/' or last.* == '\\' {
            sb.truncate(sb.len - 1)
        }
    }
    const root_len = sb.len

    let stack: Stack(WalkFrame) = stack(8, allocator)
    stack.push(WalkFrame {
        dir = root_iter,
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
        if self.stack.is_empty() {
            self.done = true
            return null
        }

        // Borrow the top frame in place - we need to mutate its RawDir.
        const top: &WalkFrame = self.stack.peek_ref().unwrap()

        const entry_opt = top.dir.next()
        if entry_opt.is_none() {
            // RawDir exhausted (or errored). Capture its error if any.
            if top.dir.last_error.is_some() and self.last_error.is_none() {
                self.last_error = top.dir.last_error
            }
            // Restore path_buf to this frame's prefix, then pop.
            self.path_buf.truncate(top.path_len_before)
            top.dir.deinit()
            const _popped = self.stack.pop()
            continue
        }
        const entry = entry_opt.unwrap()

        // Reset builder to this frame's base, then append "/<name>".
        self.path_buf.truncate(top.path_len_before)
        if self.path_buf.len > 0 {
            self.path_buf.append('/')
        }
        self.path_buf.append_bytes(entry.name.as_raw_bytes())
        const depth = self.stack.len() - 1

        const path_view = self.path_buf.as_view()
        const result = WalkEntry {
            path = path_view,
            kind = entry.kind,
            depth = depth,
        }

        // Descend into directories (not symlinks - avoid cycles).
        if is_kind_dir(entry.kind) {
            const child_r = raw_dir_open(path_view)
            if child_r.is_ok() {
                self.stack.push(WalkFrame {
                    dir = child_r.unwrap(),
                    path_len_before = self.path_buf.len,
                })
            } else if self.last_error.is_none() {
                self.last_error = Some(child_r.unwrap_err())
            }
        }

        return Some(result)
    }
    // Unreachable
    return null
}

pub fn err(self: &WalkIter) FsError? {
    return self.last_error
}

pub fn deinit(self: &WalkIter) {
    while !self.stack.is_empty() {
        const top: &WalkFrame = self.stack.peek_ref().unwrap()
        top.dir.deinit()
        const _popped = self.stack.pop()
    }
    self.stack.deinit()
    self.path_buf.deinit()
}

// =============================================================================
// Glob - built on top of walk_dir
// =============================================================================
//
// Supported pattern syntax:
//   *   matches any run of non-separator bytes within a single path segment
//   ?   matches a single non-separator byte
//   **  matches any number of path segments (including zero)
//   /   segment separator (on any platform - the shim normalizes internally)
//
// Character classes ([abc], [a-z], [!abc]) are not supported yet.
//
//     let it = glob("src/**/*.f").unwrap()
//     defer it.deinit()
//     for path in it { println(path) }
//     if it.err().is_some() { eprintln("glob failed") }

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
        root_str = pattern[..prefix_end]
    }

    // Wrap pat_buf in Owned so cleanup-on-error / transfer-on-success is
    // symmetric with the `?` exit below.
    let pat_buf = owned(string_builder(pattern.len + 1, allocator))
    defer pat_buf.deinit()
    pat_buf.append(pattern)

    let walk = walk_dir(root_str, allocator)?

    return Ok(GlobIter {
        walk = walk,
        pattern = pat_buf.transfer(),
        done = false,
    })
}

pub fn iter(self: &GlobIter) &GlobIter {
    return self
}

pub fn next(self: &GlobIter) String? {
    if self.done { return null }
    const pat_full = self.pattern.as_view()
    loop {
        const opt = self.walk.next()
        if opt.is_none() {
            self.done = true
            return null
        }
        const entry = opt.unwrap()
        if match_glob(pat_full, entry.path) {
            return Some(entry.path)
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

// =============================================================================
// Tests
// =============================================================================

test "exists and is_dir agree with the project layout" {
    assert_true(exists("flang.toml"), "flang.toml exists")
    assert_true(is_file("flang.toml"), "flang.toml is a file")
    assert_true(!is_dir("flang.toml"), "flang.toml is not a directory")
    assert_true(!exists("definitely_not_here.toml"), "missing path")
}

test "stat reports a regular file" {
    const info = stat("flang.toml")
    assert_true(info.is_ok(), "stat succeeds")
    assert_true(!is_kind_dir(info.unwrap().kind), "not a directory")
    assert_true(info.unwrap().size > 0, "non-empty")
}

test "stat on a missing path is NotFound" {
    const r = stat("definitely_not_here.toml")
    assert_true(r.is_err(), "fails")
    assert_true(r.unwrap_err() match { NotFound => true, _ => false }, "NotFound")
}

test "cwd is absolute and exists" {
    const c = cwd()
    assert_true(c.is_ok(), "cwd succeeds")
    let p = c.unwrap()
    defer p.deinit()
    assert_true(p.is_absolute(), "absolute")
    assert_true(is_dir(p.as_view()), "names a real directory")
}

test "temp_dir exists and has no trailing separator" {
    const t = temp_dir()
    assert_true(t.is_ok(), "temp_dir succeeds")
    let p = t.unwrap()
    defer p.deinit()
    assert_true(is_dir(p.as_view()), "names a real directory")
    const v = p.as_view()
    assert_true(v.len > 0 and !is_separator(v[v.len - 1]), "no trailing separator")
}

test "to_absolute leaves an absolute path alone and roots a relative one" {
    let rel = path("flang.toml")
    defer rel.deinit()
    const abs_r = to_absolute(&rel)
    assert_true(abs_r.is_ok(), "to_absolute succeeds")
    let abs = abs_r.unwrap()
    defer abs.deinit()
    assert_true(abs.is_absolute(), "result is absolute")
    assert_true(is_file(abs.as_view()), "still names the same file")

    const again = to_absolute(&abs)
    assert_true(again.is_ok(), "idempotent")
    let abs2 = again.unwrap()
    defer abs2.deinit()
    assert_true(abs2.as_view() == abs.as_view(), "unchanged when already absolute")
}

test "canonicalize requires the target to exist" {
    let missing = path("definitely_not_here.toml")
    defer missing.deinit()
    assert_true(canonicalize(&missing).is_err(), "missing path fails")

    let real = path("flang.toml")
    defer real.deinit()
    const c = canonicalize(&real)
    assert_true(c.is_ok(), "existing path succeeds")
    let resolved = c.unwrap()
    defer resolved.deinit()
    assert_true(resolved.is_absolute(), "absolute")
}

test "match_glob handles star, question mark and double star" {
    assert_true(match_glob("*.f", "main.f"), "star within a segment")
    assert_true(!match_glob("*.f", "src/main.f"), "star does not cross a separator")
    assert_true(match_glob("src/**/*.f", "src/a/b/main.f"), "double star crosses segments")
    assert_true(match_glob("src/**/*.f", "src/main.f"), "double star matches zero segments")
    assert_true(match_glob("m?in.f", "main.f"), "question mark")
    assert_true(!match_glob("m?in.f", "man.f"), "question mark needs exactly one byte")
}
