// std.io.types - the vocabulary the io modules share.
//
// A leaf module with no dependencies and no syscalls. It exists because
// `FileKind`, `FileInfo` and `FsError` are named by all four io modules, and
// the lowest of them (std.io.internal.fs) cannot import the others without a
// cycle. Putting the shared types below everything breaks the knot.
//
// It is also the module a *caller* imports when it needs qualified access:
// FLang resolves a type name transitively through an import, but a qualified
// variant (`FileKind.Dir`) only resolves when its declaring module is imported
// directly. Matching (`kind match { Dir => ... }`) needs no import at all.

pub type FileKind = enum {
    File
    Dir
    Symlink
    Other
}

pub type FileInfo = struct {
    kind: FileKind
    size: u64
}

// The one error enum the OS speaks. `std.io.file` and `std.io.dir` translate
// it into their own narrower types; nothing else re-derives it from errno.
//
// Order matters: these tag values are wired into internal/fs.c (FS_*
// constants). Appending is safe; inserting or reordering is not.
pub type FsError = enum {
    NotFound
    PermissionDenied
    NotADirectory
    NameTooLong
    NotSupported
    InvalidArgument
    IOError
    AlreadyExists
    NotEmpty
}

pub fn is_kind_dir(k: FileKind) bool {
    return k match {
        Dir => true,
        _ => false,
    }
}
