// std.path — cross-platform path manipulation.
//
// `Path` is an owning newtype wrapping a byte buffer. Queries (parent,
// file_name, file_stem, extension, components) return zero-alloc String
// views into the path's own storage — they remain valid until the Path
// is mutated or deinitialized. Operations that produce a new path (join,
// with_extension, normalize, to_absolute, cwd) may allocate.
//
// Separator handling:
//   - On Windows both '/' and '\' are recognized as separators. New joins
//     insert '\'.
//   - On every other platform only '/' is a separator.
//
//   let p = path("src/foo.f")
//   defer p.deinit()
//   let out = p.with_extension("c")    // "src/foo.c"
//   defer out.deinit()

import std.allocator
import std.list
import std.option
import std.result
import std.stack
import std.string
import std.string_builder
import std.test

// =============================================================================
// Types
// =============================================================================

pub type Path = struct {
    __sb: StringBuilder
}

pub type PathError = enum {
    IOError
    NameTooLong
    NotFound
    PermissionDenied
    InvalidArgument
}

// =============================================================================
// Separator helpers (platform-dependent)
// =============================================================================

// Native separator written by join / with_extension on this platform.
pub fn sep() u8 {
    #if(platform.os == "windows") {
        return '\\'
    } else {
        return '/'
    }
    return '/'
}

// Returns true if `b` is recognized as a path separator on this platform.
pub fn is_separator(b: u8) bool {
    #if(platform.os == "windows") {
        return b == '/' or b == '\\'
    } else {
        return b == '/'
    }
    return false
}

fn is_drive_letter(b: u8) bool {
    return (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z')
}

// =============================================================================
// Constructors
// =============================================================================

pub fn path(s: String, allocator: &Allocator? = null) Path {
    let sb = string_builder(s.len + 1, allocator)
    sb.append(s)
    return .{ __sb = sb }
}

// Takes ownership of `s` — the OwnedString is deinitialized on return.
// OwnedString and StringBuilder have different shapes (no cap field on
// OwnedString), so the bytes are copied rather than re-attached. Callers
// that care about avoiding the copy should build into a StringBuilder
// directly and skip the OwnedString entirely.
pub fn path_from_owned(s: &OwnedString) Path {
    const alloc = s.allocator
    let sb = string_builder(s.len + 1, alloc)
    sb.append(s.as_view())
    s.deinit()
    return .{ __sb = sb }
}

// =============================================================================
// Lifecycle
// =============================================================================

pub fn deinit(self: &Path) {
    self.__sb.deinit()
}

pub fn clone(self: &Path, allocator: &Allocator? = null) Path {
    return path(self.as_view(), allocator)
}

// =============================================================================
// Views
// =============================================================================

pub fn as_view(self: &Path) String {
    return self.__sb.as_view()
}

pub fn as_raw_bytes(self: &Path) u8[] {
    return slice_from_raw_parts(self.__sb.ptr, self.__sb.len)
}

pub fn len(self: &Path) usize {
    return self.__sb.len
}

pub fn is_empty(self: &Path) bool {
    return self.__sb.len == 0
}

// =============================================================================
// Predicates / queries (zero-alloc, views into self)
// =============================================================================

pub fn is_absolute(self: &Path) bool {
    const v = self.as_view()
    if v.len == 0 { return false }
    if is_separator(v[0]) { return true }
    #if(platform.os == "windows") {
        // Drive-letter path: "C:\foo" or "C:/foo". A bare "C:" is treated as
        // drive-relative, not absolute.
        if v.len >= 3 and is_drive_letter(v[0]) and v[1] == ':' and is_separator(v[2]) {
            return true
        }
    }
    return false
}

pub fn is_relative(self: &Path) bool {
    return !self.is_absolute()
}

// Returns the parent of this path, or null if there is no parent component.
// Trailing separators are ignored. The root keeps its leading separator:
//   "/foo/bar" -> "/foo"
//   "/foo"     -> "/"
//   "foo"      -> null
//   "/"        -> null
pub fn parent(self: &Path) String? {
    const v = self.as_view()
    if v.len == 0 { return null }

    // Trim trailing separators before searching.
    let end = v.len
    while end > 0 and is_separator(v[end - 1]) {
        end = end - 1
    }
    if end == 0 {
        // Pure separators (e.g. "/" or "\\\\") — no parent.
        return null
    }

    // Walk back to last separator.
    let i = end
    while i > 0 {
        i = i - 1
        if is_separator(v[i]) {
            if i == 0 {
                // Path was rooted: "/foo" -> "/"
                return v[..1]
            }
            return v[..i]
        }
    }
    return null
}

// Returns the final component as a String view, or null if the path ends in
// a separator or is empty.
pub fn file_name(self: &Path) String? {
    const v = self.as_view()
    if v.len == 0 { return null }
    if is_separator(v[v.len - 1]) { return null }

    let i: usize = v.len
    while i > 0 {
        i = i - 1
        if is_separator(v[i]) {
            return v[i + 1..]
        }
    }
    // No separator: whole path is the file name. Skip a leading drive letter
    // ("C:foo" -> "foo") on Windows.
    #if(platform.os == "windows") {
        if v.len >= 2 and is_drive_letter(v[0]) and v[1] == ':' {
            return v[2..]
        }
    }
    return v
}

// Returns the file name without its trailing extension.
// Dotfiles ("/.bashrc") are considered to have no extension — the stem is
// the whole file name.
pub fn file_stem(self: &Path) String? {
    const fname_opt = self.file_name()
    if fname_opt.is_none() { return null }
    const fname = fname_opt.unwrap()
    if fname.len == 0 { return null }

    let i: usize = fname.len
    while i > 0 {
        i = i - 1
        if fname[i] == '.' {
            if i == 0 {
                // Dotfile (".bashrc") — no extension.
                return fname
            }
            return fname[..i]
        }
    }
    return fname
}

// Returns the extension (without the dot) or null when there is none.
//   "foo.f"     -> "f"
//   "foo"       -> null
//   ".hidden"   -> null
//   "a.tar.gz"  -> "gz"
pub fn extension(self: &Path) String? {
    const fname_opt = self.file_name()
    if fname_opt.is_none() { return null }
    const fname = fname_opt.unwrap()
    if fname.len == 0 { return null }

    let i: usize = fname.len
    while i > 0 {
        i = i - 1
        if fname[i] == '.' {
            if i == 0 { return null }
            return fname[i + 1..]
        }
    }
    return null
}

// =============================================================================
// Components iterator
// =============================================================================
//
// Yields each non-empty path segment as a String view into the path's
// storage. Consecutive separators (and any leading root) are skipped — use
// is_absolute() if you need to distinguish "/foo/bar" from "foo/bar".
//
//   for c in p.components() { ... }

pub type PathComponents = struct {
    bytes: u8[]
    pos: usize
}

pub fn components(self: &Path) PathComponents {
    return .{
        bytes = self.as_raw_bytes(),
        pos = 0,
    }
}

pub fn iter(self: &PathComponents) &PathComponents {
    return self
}

pub fn next(self: &PathComponents) String? {
    while self.pos < self.bytes.len and is_separator(self.bytes[self.pos]) {
        self.pos = self.pos + 1
    }
    if self.pos >= self.bytes.len { return null }

    const start = self.pos
    while self.pos < self.bytes.len and !is_separator(self.bytes[self.pos]) {
        self.pos = self.pos + 1
    }
    return from_c_string(self.bytes.ptr + start, self.pos - start)
}

// =============================================================================
// Allocating operations
// =============================================================================

// Append `other` as a new component. If `other` is absolute, the result is
// just `other`. Uses self's allocator for the new path.
pub fn join(self: &Path, other: String) Path {
    const alloc = self.__sb.allocator

    if string_is_absolute(other) {
        return path(other, alloc)
    }

    let sb = string_builder(self.__sb.len + other.len + 1, alloc)
    sb.append(self.as_view())

    if sb.len > 0 {
        const last_ptr: &u8 = sb.ptr + (sb.len - 1)
        if !is_separator(last_ptr.*) {
            sb.append_byte(sep())
        }
    }

    // Strip a leading separator from `other` so we don't end up with "//".
    let other_start: usize = 0
    while other_start < other.len and is_separator(other[other_start]) {
        other_start = other_start + 1
    }
    sb.append(other[other_start..])

    return .{ __sb = sb }
}

// Returns a new path with the extension replaced (or added).
//   "foo.f".with_extension("c")  -> "foo.c"
//   "foo".with_extension("c")    -> "foo.c"
//   "foo.f".with_extension("")   -> "foo"
pub fn with_extension(self: &Path, ext: String) Path {
    const alloc = self.__sb.allocator
    const v = self.as_view()

    let sb = string_builder(v.len + ext.len + 2, alloc)

    // Find file-name boundary (after any final separator).
    let name_start: usize = 0
    let i: usize = v.len
    while i > 0 {
        i = i - 1
        if is_separator(v[i]) {
            name_start = i + 1
            break
        }
    }

    // Find dot inside the file-name portion (skipping leading-dot files).
    let dot_pos: usize = v.len
    let j: usize = v.len
    while j > name_start {
        j = j - 1
        if v[j] == '.' {
            if j > name_start {
                dot_pos = j
            }
            break
        }
    }

    sb.append(v[..dot_pos])
    if ext.len > 0 {
        sb.append_byte('.')
        sb.append(ext)
    }
    return .{ __sb = sb }
}

// Pure lexical normalization. Collapses "./" and resolves "../" against the
// preceding component without touching the filesystem. Symlinks are not
// resolved — use to_absolute for that level of canonicalization.
//
//   "a/./b/../c" -> "a/c"
//   "/../a"      -> "/a"
//   "a/../.."    -> ".."
pub fn normalize(self: &Path) Path {
    const alloc = self.__sb.allocator
    const v = self.as_view()

    let sb = string_builder(v.len + 1, alloc)
    // Components stored as zero-copy String views into v.
    let comps: Stack(String) = stack(8, alloc)
    defer comps.deinit()

    let has_root: bool = false
    let drive_end: usize = 0   // bytes consumed by Windows drive prefix

    #if(platform.os == "windows") {
        if v.len >= 2 and is_drive_letter(v[0]) and v[1] == ':' {
            drive_end = 2
            if v.len >= 3 and is_separator(v[2]) {
                has_root = true
                drive_end = 3
            }
        }
    }

    if drive_end == 0 and v.len > 0 and is_separator(v[0]) {
        has_root = true
    }

    // Split into components.
    let p: usize = if has_root { drive_end + (if drive_end == 0 { 1 } else { 0 }) } else { drive_end }
    while p < v.len {
        while p < v.len and is_separator(v[p]) {
            p = p + 1
        }
        if p >= v.len { break }
        const start = p
        while p < v.len and !is_separator(v[p]) {
            p = p + 1
        }
        const seg_len: usize = p - start

        if seg_len == 1 and v[start] == '.' {
            // "." — skip
            continue
        }
        if seg_len == 2 and v[start] == '.' and v[start + 1] == '.' {
            // ".." — pop unless top is also ".." (relative-only stack).
            const top_is_dotdot = comps.peek() match {
                Some(top) => top.len == 2 and top[0] == '.' and top[1] == '.',
                None => false
            }
            if !comps.is_empty() and !top_is_dotdot {
                const _popped = comps.pop()
                continue
            }
            if has_root {
                // ".." past root is a no-op.
                continue
            }
            comps.push(from_c_string(v.ptr + start, seg_len))
            continue
        }
        comps.push(from_c_string(v.ptr + start, seg_len))
    }

    // Emit drive prefix, root, then components.
    #if(platform.os == "windows") {
        if drive_end >= 2 {
            sb.append_byte(v[0])
            sb.append_byte(':')
        }
    }
    if has_root {
        sb.append_byte(sep())
    }

    const comp_slice = comps.as_slice()
    for k in 0..comp_slice.len {
        if k > 0 {
            sb.append_byte(sep())
        }
        sb.append(comp_slice[k])
    }

    if sb.len == 0 {
        sb.append_byte('.')
    }

    return .{ __sb = sb }
}

// Returns true if `s` (without constructing a Path) is an absolute path.
fn string_is_absolute(s: String) bool {
    if s.len == 0 { return false }
    if is_separator(s[0]) { return true }
    #if(platform.os == "windows") {
        if s.len >= 3 and is_drive_letter(s[0]) and s[1] == ':' and is_separator(s[2]) {
            return true
        }
    }
    return false
}

// =============================================================================
// CWD + absolute resolution
// =============================================================================

const PATH_BUF_CAP: usize = 4096

#foreign fn __flang_path_getcwd(buf: &u8, cap: usize, out_len: &usize, out_err: &i32) i32

// Returns the current working directory of the process.
pub fn cwd(allocator: &Allocator? = null) Result(Path, PathError) {
    let buf = [0u8; 4096]
    let out_len: usize = 0
    let err: i32 = 0
    const status = __flang_path_getcwd(buf.ptr, PATH_BUF_CAP, &out_len, &err)
    if status != 0 {
        return Err(err as PathError)
    }
    let sb = string_builder(out_len + 1, allocator)
    const view = from_c_string(buf.ptr, out_len)
    sb.append(view)
    return Ok(.{ __sb = sb })
}

// Returns an absolute, lexically-normalized form of this path. Does NOT
// resolve symlinks. Joins against cwd() when the path is relative.
pub fn to_absolute(self: &Path) Result(Path, PathError) {
    const alloc = self.__sb.allocator

    if self.is_absolute() {
        let n = self.normalize()
        return Ok(n)
    }

    const cwd_r = cwd(alloc)
    if cwd_r.is_err() {
        return Err(cwd_r.unwrap_err())
    }
    let base = cwd_r.unwrap()
    defer base.deinit()

    let joined = base.join(self.as_view())
    defer joined.deinit()

    let result = joined.normalize()
    return Ok(result)
}

// =============================================================================
// Tests
// =============================================================================

test "path basics" {
    let p = path("src/foo.f")
    defer p.deinit()
    assert_eq(p.as_view(), "src/foo.f", "as_view roundtrip")
    assert_eq(p.len(), 9, "len")
    assert_true(!p.is_empty(), "non-empty")
}

test "is_absolute on relative paths" {
    let p = path("src/foo")
    defer p.deinit()
    assert_true(!p.is_absolute(), "src/foo is relative")
    assert_true(p.is_relative(), "is_relative inverse")
}

test "is_absolute on rooted paths" {
    let p = path("/src/foo")
    defer p.deinit()
    #if(platform.os == "windows") {
        // On Windows '/' alone is still treated as a rooted path.
        assert_true(p.is_absolute(), "/src/foo is absolute on Windows")
    } else {
        assert_true(p.is_absolute(), "/src/foo is absolute")
    }
}

test "parent of nested path" {
    let p = path("src/foo/bar.f")
    defer p.deinit()
    const par = p.parent()
    assert_true(par.is_some(), "has parent")
    assert_eq(par.unwrap(), "src/foo", "parent of nested")
}

test "parent of single component" {
    let p = path("foo.f")
    defer p.deinit()
    assert_true(p.parent().is_none(), "single component has no parent")
}

test "parent of rooted single" {
    let p = path("/foo")
    defer p.deinit()
    const par = p.parent()
    assert_true(par.is_some(), "parent of /foo")
    assert_eq(par.unwrap(), "/", "/foo parent is /")
}

test "parent of root only" {
    let p = path("/")
    defer p.deinit()
    assert_true(p.parent().is_none(), "/ has no parent")
}

test "file_name typical" {
    let p = path("src/foo/bar.f")
    defer p.deinit()
    const f = p.file_name()
    assert_true(f.is_some(), "has file_name")
    assert_eq(f.unwrap(), "bar.f", "file_name")
}

test "file_name with trailing sep" {
    let p = path("src/foo/")
    defer p.deinit()
    assert_true(p.file_name().is_none(), "trailing sep -> no file")
}

test "file_stem and extension" {
    let p = path("src/foo.bar.tar.gz")
    defer p.deinit()
    assert_eq(p.file_stem().unwrap(), "foo.bar.tar", "stem")
    assert_eq(p.extension().unwrap(), "gz", "ext")
}

test "extension of dotfile" {
    let p = path(".bashrc")
    defer p.deinit()
    assert_true(p.extension().is_none(), "dotfile has no extension")
    assert_eq(p.file_stem().unwrap(), ".bashrc", "stem is full dotfile name")
}

test "extension absent" {
    let p = path("Makefile")
    defer p.deinit()
    assert_true(p.extension().is_none(), "Makefile -> no ext")
    assert_eq(p.file_stem().unwrap(), "Makefile", "Makefile stem")
}

test "join simple" {
    let p = path("src")
    defer p.deinit()
    let j = p.join("foo.f")
    defer j.deinit()
    #if(platform.os == "windows") {
        assert_eq(j.as_view(), "src\\foo.f", "windows join")
    } else {
        assert_eq(j.as_view(), "src/foo.f", "posix join")
    }
}

test "join absolute replaces" {
    let p = path("src")
    defer p.deinit()
    let j = p.join("/etc/hosts")
    defer j.deinit()
    assert_eq(j.as_view(), "/etc/hosts", "absolute join replaces")
}

test "join with trailing sep" {
    let p = path("src/")
    defer p.deinit()
    let j = p.join("foo.f")
    defer j.deinit()
    assert_eq(j.as_view(), "src/foo.f", "no duplicate sep")
}

test "with_extension replace" {
    let p = path("src/foo.f")
    defer p.deinit()
    let q = p.with_extension("c")
    defer q.deinit()
    assert_eq(q.as_view(), "src/foo.c", "ext replaced")
}

test "with_extension add" {
    let p = path("Makefile")
    defer p.deinit()
    let q = p.with_extension("bak")
    defer q.deinit()
    assert_eq(q.as_view(), "Makefile.bak", "ext added")
}

test "with_extension strip" {
    let p = path("src/foo.f")
    defer p.deinit()
    let q = p.with_extension("")
    defer q.deinit()
    assert_eq(q.as_view(), "src/foo", "ext stripped")
}

test "normalize collapses dots" {
    let p = path("a/./b/../c")
    defer p.deinit()
    let n = p.normalize()
    defer n.deinit()
    #if(platform.os == "windows") {
        assert_eq(n.as_view(), "a\\c", "windows normalize")
    } else {
        assert_eq(n.as_view(), "a/c", "posix normalize")
    }
}

test "normalize past root" {
    let p = path("/../a")
    defer p.deinit()
    let n = p.normalize()
    defer n.deinit()
    #if(platform.os == "windows") {
        assert_eq(n.as_view(), "\\a", "windows normalize past root")
    } else {
        assert_eq(n.as_view(), "/a", ".. past root is no-op")
    }
}

test "normalize empty -> dot" {
    let p = path("")
    defer p.deinit()
    let n = p.normalize()
    defer n.deinit()
    assert_eq(n.as_view(), ".", "empty normalizes to .")
}

test "cwd returns a path" {
    const r = cwd()
    assert_true(r.is_ok(), "cwd ok")
    let p = r.unwrap()
    defer p.deinit()
    assert_true(p.len() > 0, "cwd non-empty")
    assert_true(p.is_absolute(), "cwd is absolute")
}
