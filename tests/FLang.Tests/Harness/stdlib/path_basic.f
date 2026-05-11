//! TEST: path_basic
//! EXIT: 0

import std.option
import std.path
import std.result

pub fn main() i32 {
    // Constructors + views
    let p = path("src/foo.f")
    defer p.deinit()
    if p.as_view() != "src/foo.f" { return 1 }
    if p.len() != 9 { return 2 }
    if p.is_empty() { return 3 }

    // Relative vs absolute
    if p.is_absolute() { return 10 }
    if !p.is_relative() { return 11 }

    let abs = path("/etc/hosts")
    defer abs.deinit()
    if !abs.is_absolute() { return 12 }

    // parent
    const par = p.parent()
    if par.is_none() { return 20 }
    if par.unwrap() != "src" { return 21 }

    let lone = path("foo.f")
    defer lone.deinit()
    if lone.parent().is_some() { return 22 }

    let rooted = path("/foo")
    defer rooted.deinit()
    if rooted.parent().unwrap() != "/" { return 23 }

    let root_only = path("/")
    defer root_only.deinit()
    if root_only.parent().is_some() { return 24 }

    // file_name / file_stem / extension
    if p.file_name().unwrap() != "foo.f" { return 30 }
    if p.file_stem().unwrap() != "foo" { return 31 }
    if p.extension().unwrap() != "f" { return 32 }

    let trailing = path("src/foo/")
    defer trailing.deinit()
    if trailing.file_name().is_some() { return 33 }

    let dotfile = path(".bashrc")
    defer dotfile.deinit()
    if dotfile.extension().is_some() { return 34 }
    if dotfile.file_stem().unwrap() != ".bashrc" { return 35 }

    let nover = path("Makefile")
    defer nover.deinit()
    if nover.extension().is_some() { return 36 }
    if nover.file_stem().unwrap() != "Makefile" { return 37 }

    let multi = path("src/foo.tar.gz")
    defer multi.deinit()
    if multi.extension().unwrap() != "gz" { return 38 }
    if multi.file_stem().unwrap() != "foo.tar" { return 39 }

    // join — absolute replaces; trailing-sep no-dup
    let s = path("src")
    defer s.deinit()
    let j = s.join("foo.f")
    defer j.deinit()
    // Either '/' or '\' is acceptable depending on platform.
    if j.file_name().unwrap() != "foo.f" { return 40 }
    if j.parent().unwrap() != "src" { return 41 }

    let j_abs = s.join("/etc/hosts")
    defer j_abs.deinit()
    if j_abs.as_view() != "/etc/hosts" { return 42 }

    let trail = path("src/")
    defer trail.deinit()
    let j_trail = trail.join("foo.f")
    defer j_trail.deinit()
    if j_trail.file_name().unwrap() != "foo.f" { return 43 }
    if j_trail.parent().unwrap() != "src" { return 44 }

    // with_extension
    let we = p.with_extension("c")
    defer we.deinit()
    if we.as_view() != "src/foo.c" { return 50 }

    let we_add = nover.with_extension("bak")
    defer we_add.deinit()
    if we_add.as_view() != "Makefile.bak" { return 51 }

    let we_strip = p.with_extension("")
    defer we_strip.deinit()
    if we_strip.as_view() != "src/foo" { return 52 }

    // normalize
    let dirty = path("a/./b/../c")
    defer dirty.deinit()
    let n = dirty.normalize()
    defer n.deinit()
    if n.file_name().unwrap() != "c" { return 60 }
    if n.parent().unwrap() != "a" { return 61 }

    let empty = path("")
    defer empty.deinit()
    let n2 = empty.normalize()
    defer n2.deinit()
    if n2.as_view() != "." { return 62 }

    // cwd returns an absolute, non-empty path
    const r = cwd()
    if r.is_err() { return 70 }
    let c = r.unwrap()
    defer c.deinit()
    if c.len() == 0 { return 71 }
    if !c.is_absolute() { return 72 }

    // components iterator
    let comp_src = path("src/foo/bar.f")
    defer comp_src.deinit()
    let it = comp_src.components()
    let count: i32 = 0
    for seg in it {
        count = count + 1
    }
    if count != 3 { return 80 }

    return 0
}
