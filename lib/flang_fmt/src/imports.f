// Import ordering. The leading import block of a module is rewritten into groups - `core`, `std`,
// everything else (dependencies), the project's own modules - one blank line between groups,
// alphabetical by dotted
// path within a group (so a package façade sits directly above its children), `pub import` sorted
// in with the rest. An own-line comment above an import travels with it; a trailing comment is part
// of its line. Exact duplicates collapse to the first. Nothing outside the block moves, and the
// block ends at the first line that is neither an import, a comment nor blank - an import inside a
// decl-level `#if` stays where it is.
//
// Runs on the text before the formatter parses it, so the renderer's token check sees the sorted
// source as its input.

import std.list
import std.option
import std.sort
import std.string
import std.string_builder
import std.test

const GROUP_CORE: usize = 0
const GROUP_STD: usize = 1
const GROUP_DEPS: usize = 2
const GROUP_PROJECT: usize = 3

// One import and the comment lines that ride above it: `lines[first..line]` are the comments,
// `lines[line]` the import itself.
type ImportEntry = struct {
    first: usize
    line: usize
    path: String
    is_pub: bool
    group: usize
}

// `source` with its import block sorted. `project` is the manifest's name; with no manifest it is
// empty and every non-`core`, non-`std` import lands in the dependency group.
pub fn sort_imports(source: String, project: String, eol: String) OwnedString {
    let lines = split_lines(source, eol)
    defer lines.deinit()

    let first_import = lines.len
    for i in 0..lines.len {
        if import_path(lines[i]).is_some() {
            first_import = i
            break
        }
    }
    if first_import == lines.len {
        return from_view(source)
    }

    let entries: List(ImportEntry) = list(16)
    defer entries.deinit()
    let pending: usize? = null
    let block_end = first_import
    let i = first_import
    while i < lines.len {
        const l = lines[i]
        const path = import_path(l)
        if path.is_some() {
            entries.push(ImportEntry {
                first = pending.unwrap_or(i),
                line = i,
                path = path.unwrap(),
                is_pub = starts_with(l, "pub "),
                group = group_of(path.unwrap(), project),
            })
            pending = null
            block_end = i + 1
        } else if is_comment(l) {
            if pending.is_none() {
                pending = Some(i)
            }
        } else if !is_blank(l) {
            break
        }
        i = i + 1
    }

    insertion_sort(entries.as_slice(), order)

    let sb = string_builder(source.len + 16)
    defer sb.deinit()
    for j in 0..first_import {
        sb.append(lines[j])
        sb.append(eol)
    }
    let prev: ImportEntry? = null
    for &e in entries {
        if prev.is_some() and e.path == prev.unwrap().path and e.is_pub == prev.unwrap().is_pub {
            continue
        }
        if prev.is_some() and e.group != prev.unwrap().group {
            sb.append(eol)
        }
        for j in e.first..(e.line + 1) {
            sb.append(lines[j])
            sb.append(eol)
        }
        prev = Some(e.*)
    }
    for j in block_end..lines.len {
        sb.append(lines[j])
        if j + 1 < lines.len {
            sb.append(eol)
        }
    }
    return sb.to_string()
}

// The dotted path of an `import` / `pub import` line, or null for any other line.
fn import_path(line: String) String? {
    let rest = line
    if starts_with(rest, "pub ") {
        rest = rest[4..rest.len]
    }
    if !starts_with(rest, "import ") {
        return null
    }
    rest = rest[7..rest.len]
    let end = 0usize
    while end < rest.len and rest[end] != ' ' and rest[end] != '\t' and rest[end] != '/' {
        end = end + 1
    }
    return if end == 0 { null } else { Some(rest[0..end]) }
}

fn group_of(path: String, project: String) usize {
    let end = 0usize
    while end < path.len and path[end] != '.' {
        end = end + 1
    }
    const head = path[0..end]
    if head == "core" {
        return GROUP_CORE
    }
    if head == "std" {
        return GROUP_STD
    }
    if project.len > 0 and head == project {
        return GROUP_PROJECT
    }
    // Every other root is a dependency, declared or not: a single-file format has no manifest to
    // consult, and the order is the same either way.
    return GROUP_DEPS
}

// (group, path, pub): a block is a few dozen lines at most, and insertion sort is stable.
fn order(a: ImportEntry, b: ImportEntry) Ord {
    if a.group != b.group {
        return op_cmp(a.group, b.group)
    }
    if a.path != b.path {
        return op_cmp(a.path, b.path)
    }
    return op_cmp(a.is_pub, b.is_pub)
}

fn is_comment(line: String) bool {
    let i = 0usize
    while i < line.len and (line[i] == ' ' or line[i] == '\t') {
        i = i + 1
    }
    return i + 1 < line.len and line[i] == '/' and line[i + 1] == '/'
}

fn is_blank(line: String) bool {
    for c in line.as_raw_bytes() {
        if c != ' ' and c != '\t' {
            return false
        }
    }
    return true
}

fn starts_with(s: String, prefix: String) bool {
    return s.len >= prefix.len and s[0..prefix.len] == prefix
}

// `source` cut at every `eol`, the terminator removed. A source ending in `eol` yields a final
// empty line, so joining with `eol` between lines recovers the text exactly.
fn split_lines(source: String, eol: String) List(String) {
    let lines: List(String) = list(64)
    let start = 0usize
    let i = 0usize
    while i < source.len {
        if source[i] == '\n' {
            const end = if eol.len == 2 and i > 0 and source[i - 1] == '\r' { i - 1 } else { i }
            lines.push(source[start..end])
            start = i + 1
        }
        i = i + 1
    }
    lines.push(source[start..source.len])
    return lines
}

// =============================================================================
// Tests
// =============================================================================

fn sorted(src: String) OwnedString {
    return sort_imports(src, "flang_fmt", "\n")
}

test "groups core, std, dependencies and the project, blank line between" {
    const out = sorted("import flang_fmt.fmt\nimport std.list\nimport flang_parser.ast\nimport core.math\nimport flang_core.span\n\nfn f() {}\n")
    defer out.deinit()
    assert_eq(out.as_view(),
        "import core.math\n\nimport std.list\n\nimport flang_core.span\nimport flang_parser.ast\n\nimport flang_fmt.fmt\n\nfn f() {}\n",
        "grouped")
}

test "alphabetical by dotted path puts a package above its children" {
    const out = sorted("import std.time\nimport std.io.file\nimport std.io\nimport std.string_builder\nimport std.string\n")
    defer out.deinit()
    assert_eq(out.as_view(),
        "import std.io\nimport std.io.file\nimport std.string\nimport std.string_builder\nimport std.time\n",
        "sorted")
}

test "a comment above an import travels with it, a trailing one stays on its line" {
    const out = sorted("import std.string // explicit\n// Re-exported for callers.\npub import std.format\nimport std.dict\n")
    defer out.deinit()
    assert_eq(out.as_view(),
        "import std.dict\n// Re-exported for callers.\npub import std.format\nimport std.string // explicit\n",
        "comments")
}

test "the file header, blank lines and what follows the block do not move" {
    const out = sorted("// Module doc.\n\nimport std.string\n\nimport std.dict\n\n// About f.\nfn f() {}\n")
    defer out.deinit()
    assert_eq(out.as_view(),
        "// Module doc.\n\nimport std.dict\nimport std.string\n\n// About f.\nfn f() {}\n",
        "surroundings")
}

test "duplicates collapse and an unknown root sorts with the dependencies" {
    const out = sorted("import std.list\nimport other.thing\nimport std.list\nimport flang_fmt.a\n")
    defer out.deinit()
    assert_eq(out.as_view(), "import std.list\n\nimport other.thing\n\nimport flang_fmt.a\n",
        "dedupe")
}

test "an import inside a directive block ends the sortable block" {
    const out = sorted("import std.string\nimport std.dict\n#if platform.os == \"windows\" {\n    import std.terminal\n}\n")
    defer out.deinit()
    assert_eq(out.as_view(),
        "import std.dict\nimport std.string\n#if platform.os == \"windows\" {\n    import std.terminal\n}\n",
        "directive")
}

test "no imports is a no-op, CRLF is preserved" {
    const none = sorted("fn f() {}\n")
    defer none.deinit()
    assert_eq(none.as_view(), "fn f() {}\n", "no block")
    const crlf = sort_imports("import std.string\r\nimport std.dict\r\n\r\nfn f() {}\r\n", "",
        "\r\n")
    defer crlf.deinit()
    assert_eq(crlf.as_view(), "import std.dict\r\nimport std.string\r\n\r\nfn f() {}\r\n", "crlf")
}
