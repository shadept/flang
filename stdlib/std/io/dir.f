// std.io.dir - an open directory and the operations that need one.
//
// Sits on std.io.internal.fs, which owns every syscall. This module holds a
// Dir and reports `DirError`: the set of things that can go wrong when the
// thing you named is meant to be a directory. `NotEmpty` is in it and
// `remove_dir` is the only way to hit that; file-shaped failures are not.
//
//     let d = open_dir("src").unwrap()
//     defer d.deinit()
//     for entry in d {
//         println(entry.name)   // valid only until the next iteration
//     }
//     if d.err().is_some() { eprintln("read failed") }
//
// "." and ".." are filtered at the syscall layer - callers never see them.

import std.allocator
import std.list
import std.option
import std.owned
import std.path
import std.result
import std.string
import std.string_builder
import std.test
import std.io.fs
import std.io.internal.fs
import std.io.types

pub type DirError = enum {
    IOError,
    NotFound,
    PermissionDenied,
    NotADirectory,
    AlreadyExists,
    NotEmpty,
    NameTooLong,
    InvalidArgument,
}

// `name` is a view into the owning Dir's buffer and is invalidated by the next
// iteration. Callers that accumulate entries must clone into an OwnedString.
pub type DirEntry = struct {
    name: String
    kind: FileKind
}

// `path` is the view the caller opened with, kept so the convenience methods
// below have a root to work from. Borrowed, exactly like `File.path`.
pub type Dir = struct {
    path: String
    raw: RawDir
}

// =============================================================================
// Error translation
// =============================================================================

// The OS speaks FsError; this module speaks DirError. This is the only place
// the two meet, so a new errno mapping is added once, in fs.c, and lands here
// automatically.
fn to_dir_error(e: FsError) DirError {
    return e match {
        NotFound => DirError.NotFound,
        PermissionDenied => DirError.PermissionDenied,
        NotADirectory => DirError.NotADirectory,
        AlreadyExists => DirError.AlreadyExists,
        NotEmpty => DirError.NotEmpty,
        NameTooLong => DirError.NameTooLong,
        InvalidArgument => DirError.InvalidArgument,
        _ => DirError.IOError,
    }
}

// =============================================================================
// Open / iterate / close
// =============================================================================

pub fn open_dir(path: String) Result(Dir, DirError) {
    const raw = raw_dir_open(path).map_err(to_dir_error)?
    return Ok(Dir { path = path, raw = raw })
}

// Borrowing rather than copying means `d.err()` still reports what happened
// after `for entry in d` ends.
pub fn iter(self: &Dir) &Dir {
    return self
}

pub fn next(self: &Dir) DirEntry? {
    const entry = self.raw.next()?
    return Some(DirEntry { name = entry.name, kind = entry.kind })
}

// True once iteration has run out of entries or stopped on an error. Pair with
// `err()` to tell the two apart.
pub fn is_done(self: &Dir) bool {
    return self.raw.done
}

// The error that ended iteration, if iteration ended badly rather than simply
// running out of entries.
pub fn err(self: &Dir) DirError? {
    return self.raw.err().map(to_dir_error)
}

pub fn deinit(self: &Dir) {
    self.raw.deinit()
}

// =============================================================================
// Creation
// =============================================================================

// Creates a single directory. Parents must already exist - use `create_dir_all`
// when they might not. Errs with AlreadyExists if `path` is taken.
pub fn create_dir(path: String) Result((), DirError) {
    return raw_mkdir(path).map_err(to_dir_error)
}

// Creates one directory, treating an existing one as success. An existing
// *file* is NotADirectory, so a name collision is never mistaken for a usable
// directory.
fn ensure_dir(path: String) Result((), DirError) {
    raw_mkdir(path) match {
        Ok(_) => return Ok(()),
        // Already taken: fine if it is a directory, a hard error otherwise.
        Err(AlreadyExists) => {},
        Err(e) => return Err(to_dir_error(e)),
    }

    const info = raw_stat(path).map_err(to_dir_error)?
    if !is_kind_dir(info.kind) { return Err(DirError.NotADirectory) }
    return Ok(())
}

// Creates `path` and every missing ancestor. Idempotent: an existing directory
// is success. Each prefix is a view into `path`, so no per-component
// allocation happens - internal copies once, at the syscall boundary.
pub fn create_dir_all(path: String) Result((), DirError) {
    if path.len == 0 { return Err(DirError.InvalidArgument) }

    // Start at 1: index 0 is either a relative first character or the POSIX
    // root, and neither is a prefix worth creating.
    let i: usize = 1
    while i < path.len {
        if is_separator(path[i]) and !is_prefix_unbuildable(path, i) {
            ensure_dir(path[..i])?
        }
        i = i + 1
    }
    return ensure_dir(path)
}

// True for prefixes that cannot themselves be created: a repeated separator
// (`a//b`) and a Windows drive root (`C:\\foo`).
fn is_prefix_unbuildable(p: String, i: usize) bool {
    if i == 0 { return true }
    if is_separator(p[i - 1]) { return true }
    return i == 2 and p[1] == ':'
}

// =============================================================================
// Removal
// =============================================================================

// Deletes an empty directory. A populated one is NotEmpty - use
// `remove_dir_all` when the contents are meant to go too.
pub fn remove_dir(path: String) Result((), DirError) {
    return raw_rmdir(path).map_err(to_dir_error)
}

// One entry scheduled for deletion. `path` is owned because the walk's own
// view dies on the next iteration, and deletion happens after the walk ends.
type Doomed = struct {
    path: OwnedString
    is_dir: bool
}

fn free_doomed(items: &List(Doomed)) {
    for item in items.iter_ref() {
        item.path.deinit()
    }
    items.deinit()
}

// Deletes `path` and everything under it. Symlinks are removed as links -
// never followed - so a link out of the tree cannot widen the blast radius.
//
// The whole tree is collected before the first deletion: readdir behaviour
// while a directory is being modified is implementation-defined. That costs
// one owned path per entry, which is the right trade for a build directory
// and the wrong one for a filesystem root.
pub fn remove_dir_all(path: String, allocator: &Allocator? = null) Result((), DirError) {
    let walk = walk_dir(path, allocator).map_err(to_dir_error)?
    defer walk.deinit()

    let doomed: List(Doomed) = list(64, allocator)
    defer free_doomed(&doomed)

    for entry in walk {
        doomed.push(Doomed {
            path = from_view(entry.path, allocator),
            is_dir = is_kind_dir(entry.kind),
        })
    }
    const walk_err = walk.err()
    if walk_err.is_some() { return Err(to_dir_error(walk_err.unwrap())) }

    // walk_dir is pre-order, so a parent always precedes its children.
    // Deleting backwards therefore empties every directory before removing it.
    let i = doomed.len
    while i > 0 {
        i = i - 1
        const item: &Doomed = doomed.op_index_ref(i)
        const view = item.path.as_view()
        // A file that will not unlink is a failure of the directory removal,
        // so it is reported as one.
        const r = if item.is_dir { remove_dir(view) } else { raw_unlink(view).map_err(to_dir_error) }
        if r.is_err() { return r }
    }
    return remove_dir(path)
}

// =============================================================================
// Convenience over std.io.fs
// =============================================================================
//
// Traversal lives in std.io.fs because it yields paths rather than handles.
// These wrappers exist so that holding a Dir does not force a caller back out
// to a path-level API for the obvious next question.

// Walks the tree rooted at this directory, pre-order, without following
// symlinks. See std.io.fs.walk_dir.
pub fn walk(self: &Dir, allocator: &Allocator? = null) Result(WalkIter, FsError) {
    return walk_dir(self.path, allocator)
}

// Matches `pattern` relative to this directory: `d.glob("**/*.f")` is
// `glob("<d>/**/*.f")`. See std.io.fs.glob.
pub fn glob(self: &Dir, pattern: String, allocator: &Allocator? = null) Result(GlobIter, FsError) {
    let joined = string_builder(self.path.len + pattern.len + 1, allocator)
    defer joined.deinit()
    joined.append(self.path)
    if self.path.len > 0 and !is_separator(self.path[self.path.len - 1]) {
        joined.append('/')
    }
    joined.append(pattern)
    return glob(joined.as_view(), allocator)
}

// =============================================================================
// Tests
// =============================================================================
//
// Fixtures live under `build/` and are removed at the end of each test, so a
// re-run starts clean.

const TEST_ROOT = "build/dir_test_tree"

test "create_dir_all creates a nested tree" {
    const leaf = "build/dir_test_tree/a/b/c"
    assert_true(create_dir_all(leaf).is_ok(), "create_dir_all succeeds")
    assert_true(is_dir(TEST_ROOT), "root created")
    assert_true(is_dir(leaf), "leaf created")
    assert_true(remove_dir_all(TEST_ROOT).is_ok(), "cleanup")
}

test "create_dir_all is idempotent" {
    const leaf = "build/dir_test_tree/a/b/c"
    assert_true(create_dir_all(leaf).is_ok(), "first call")
    assert_true(create_dir_all(leaf).is_ok(), "second call on an existing tree")
    assert_true(remove_dir_all(TEST_ROOT).is_ok(), "cleanup")
}

test "create_dir_all rejects a path blocked by a file" {
    // Colocated tests run from the project root, where flang.toml is always a
    // file - so nothing under it can ever be a directory.
    const r = create_dir_all("flang.toml/nope")
    assert_true(r.is_err(), "file in the middle of the path")
    assert_true(r.unwrap_err() match { NotADirectory => true, _ => false }, "NotADirectory")
    assert_true(!exists("flang.toml/nope"), "nothing was created")
}

test "create_dir errs on an existing directory" {
    assert_true(create_dir_all(TEST_ROOT).is_ok(), "setup")
    const r = create_dir(TEST_ROOT)
    assert_true(r.is_err(), "second create fails")
    assert_true(r.unwrap_err() match { AlreadyExists => true, _ => false }, "AlreadyExists")
    assert_true(remove_dir_all(TEST_ROOT).is_ok(), "cleanup")
}

test "create_dir_all rejects an empty path" {
    assert_true(create_dir_all("").is_err(), "empty path")
}

test "remove_dir removes an empty directory" {
    assert_true(create_dir_all(TEST_ROOT).is_ok(), "setup")
    assert_true(remove_dir(TEST_ROOT).is_ok(), "remove_dir succeeds")
    assert_true(!exists(TEST_ROOT), "gone")
}

test "remove_dir refuses a populated directory" {
    assert_true(create_dir_all("build/dir_test_tree/child").is_ok(), "setup")
    const r = remove_dir(TEST_ROOT)
    assert_true(r.is_err(), "remove_dir fails")
    assert_true(r.unwrap_err() match { NotEmpty => true, _ => false }, "NotEmpty")
    assert_true(is_dir(TEST_ROOT), "left intact")
    assert_true(remove_dir_all(TEST_ROOT).is_ok(), "cleanup")
}

test "remove_dir_all removes a nested tree" {
    assert_true(create_dir_all("build/dir_test_tree/a/b/c").is_ok(), "setup deep")
    assert_true(create_dir_all("build/dir_test_tree/a/sibling").is_ok(), "setup sibling")
    assert_true(remove_dir_all(TEST_ROOT).is_ok(), "remove_dir_all succeeds")
    assert_true(!exists(TEST_ROOT), "whole tree gone")
}

test "remove_dir_all on a missing path is NotFound" {
    const r = remove_dir_all("build/dir_test_definitely_missing")
    assert_true(r.is_err(), "fails")
    assert_true(r.unwrap_err() match { NotFound => true, _ => false }, "NotFound")
}

test "open_dir yields entries and filters dot entries" {
    assert_true(create_dir_all("build/dir_test_tree/only_child").is_ok(), "setup")

    let d = open_dir(TEST_ROOT).unwrap()
    defer d.deinit()

    let count: usize = 0
    let saw_child = false
    for entry in d {
        count = count + 1
        if entry.name == "only_child" { saw_child = true }
        assert_true(entry.name != "." and entry.name != "..", "dot entries filtered")
    }
    assert_eq(count, 1, "exactly one entry")
    assert_true(saw_child, "found the child by name")
    assert_true(d.err().is_none(), "iteration ended cleanly")

    assert_true(remove_dir_all(TEST_ROOT).is_ok(), "cleanup")
}

test "Dir.walk and Dir.glob are rooted at the directory" {
    assert_true(create_dir_all("build/dir_test_tree/a/b").is_ok(), "setup")

    let d = open_dir(TEST_ROOT).unwrap()
    defer d.deinit()

    let w = d.walk().unwrap()
    defer w.deinit()
    let seen: usize = 0
    for entry in w {
        seen = seen + 1
        assert_true(entry.path.starts_with(TEST_ROOT), "walk stays under the root")
    }
    assert_eq(seen, 2, "a and a/b")

    let g = d.glob("**/b").unwrap()
    defer g.deinit()
    let matched: usize = 0
    for hit in g {
        matched = matched + 1
        assert_eq(hit, "build/dir_test_tree/a/b", "glob is rooted at the directory")
    }
    assert_eq(matched, 1, "one match")

    assert_true(remove_dir_all(TEST_ROOT).is_ok(), "cleanup")
}

test "open_dir on a missing path is NotFound" {
    const r = open_dir("build/dir_test_definitely_missing")
    assert_true(r.is_err(), "fails")
    assert_true(r.unwrap_err() match { NotFound => true, _ => false }, "NotFound")
}
