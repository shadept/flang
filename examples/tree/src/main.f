// ftree — directory tree viewer, modelled on GNU `tree(1)`.
//
// Usage:
//   ftree [options] [path ...]
//
// Options:
//   -L, --level N     Descend at most N levels (max-depth)
//   -a, --all         Include hidden entries (names starting with '.')
//   -d, --dirs-only   List directories only
//   -f, --full-path   Print full path prefix for each entry
//   -F, --classify    Append '/' to directory names
//   -s, --size        Show file sizes (bytes) in square brackets
//   -h, --human       Show sizes in human-readable form (K/M/G/T); implies -s
//   -I, --ignore PAT  Exclude entries whose basename matches glob PAT
//       --noreport    Omit the trailing directory/file summary
//       --ascii       Use ASCII instead of Unicode box-drawing
//       --help        Show this help and exit

import std.io.fs
import std.env
import std.list
import std.string
import std.string_builder
import std.option
import std.result
import std.allocator
import std.conv
import std.sort

// -----------------------------------------------------------------------------
// Types
// -----------------------------------------------------------------------------

type Entry = struct {
    name: OwnedString
    kind: FileKind
}

fn entry_cmp(a: Entry, b: Entry) Ord {
    return op_cmp(a.name.as_view(), b.name.as_view())
}

type State = struct {
    max_depth: usize        // 0 = unlimited
    show_hidden: bool
    dirs_only: bool
    full_path: bool
    classify: bool
    show_size: bool
    human_size: bool
    ascii: bool
    no_report: bool
    ignore_pattern: String
    dir_count: usize
    file_count: usize
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

fn ends_with_sep(s: String) bool {
    if s.len == 0 { return false }
    const c = s[s.len - 1]
    return c == '/' or c == '\\'
}

// Null-terminate the builder's contents in-place (without bumping len) so the
// buffer can be passed to read_dir/stat as a C string. Mirrors the idiom used
// inside std.io.fs.walk_dir.
fn ensure_nul_term(sb: &StringBuilder) {
    sb.ensure_capacity(sb.len + 1)
    const term: &u8 = sb.ptr + sb.len
    term.* = 0
}

// Append `base/name` into sb, skipping the separator when base already ends
// with one (so root paths like "C:\" or "/" stay intact).
fn append_join(sb: &StringBuilder, base: String, name: String) {
    sb.append(base)
    if base.len > 0 and !ends_with_sep(base) {
        sb.append("/")
    }
    sb.append(name)
}

// Human-readable size: <1024 → raw bytes, otherwise scaled to K/M/G/T/P/E
// with one fractional digit. Matches tree's `-h` output shape.
fn append_human_size(sb: &StringBuilder, n: u64) {
    if n < 1024 {
        sb.append(n)
        return
    }
    let value = n as f64 / 1024.0
    let unit_idx: usize = 0
    while value >= 1024.0 and unit_idx < 5 {
        value = value / 1024.0
        unit_idx = unit_idx + 1
    }
    sb.append(value, ".1")
    if unit_idx == 0 { sb.append("K") }
    else if unit_idx == 1 { sb.append("M") }
    else if unit_idx == 2 { sb.append("G") }
    else if unit_idx == 3 { sb.append("T") }
    else if unit_idx == 4 { sb.append("P") }
    else { sb.append("E") }
}

fn free_entries(entries: &List(Entry)) {
    for i in 0..entries.len {
        entries[i].name.deinit()
    }
    entries.deinit()
}

// -----------------------------------------------------------------------------
// Directory listing
// -----------------------------------------------------------------------------

fn collect_entries(path: String, state: &State) Result(List(Entry), FsError) {
    let entries: List(Entry) = list(16)

    const it_r = read_dir(path)
    if it_r.is_err() {
        entries.deinit()
        return Err(it_r.unwrap_err())
    }
    let it = it_r.unwrap()
    defer it.deinit()

    for e in it {
        if !state.show_hidden and e.name.len > 0 and e.name[0] == '.' { continue }

        if state.ignore_pattern.len > 0 and match_glob(state.ignore_pattern, e.name) {
            continue
        }

        if state.dirs_only and e.kind != FileKind.Dir { continue }

        // `e.name` is a view into the iterator's internal buffer — invalidated
        // on the next next() call, so take an owning copy.
        const owned = from_view(e.name)
        entries.push(Entry { name = owned, kind = e.kind })
    }

    const err = it.err()
    if err.has_value {
        free_entries(&entries)
        return Err(err.value)
    }

    entries.sort(entry_cmp)
    return Ok(entries)
}

// -----------------------------------------------------------------------------
// Rendering
// -----------------------------------------------------------------------------

fn render_line(prefix: String, is_last: bool, path: String, entry: &Entry, state: &State) {
    let sb = string_builder(prefix.len + entry.name.len + 16)
    defer sb.deinit()

    sb.append(prefix)
    if state.ascii {
        if is_last { sb.append("`-- ") } else { sb.append("|-- ") }
    } else {
        if is_last { sb.append("└── ") } else { sb.append("├── ") }
    }

    if state.full_path {
        sb.append(path)
        if path.len > 0 and !ends_with_sep(path) { sb.append("/") }
    }

    sb.append(entry.name.as_view())

    if state.classify and entry.kind == FileKind.Dir {
        sb.append("/")
    }

    if state.show_size and entry.kind != FileKind.Dir {
        let stat_sb = string_builder(path.len + entry.name.len + 2)
        defer stat_sb.deinit()
        append_join(&stat_sb, path, entry.name.as_view())
        ensure_nul_term(&stat_sb)

        const info_r = stat(stat_sb.as_view())
        let size: u64 = 0
        info_r match {
            Ok(info) => { size = info.size }
            Err(_) => {}
        }

        sb.append(" [")
        if state.human_size { append_human_size(&sb, size) }
        else { sb.append(size) }
        sb.append("]")
    }

    println(sb.as_view())
}

// Depth-first pre-order walk. `path` must be null-terminated — callers pass
// either the original argv string (already NUL-terminated by the C runtime)
// or a StringBuilder-built path run through `ensure_nul_term`.
fn walk(path: String, prefix: String, depth: usize, state: &State) {
    const entries_r = collect_entries(path, state)
    if entries_r.is_err() {
        let sb = string_builder(prefix.len + 20)
        defer sb.deinit()
        sb.append(prefix)
        sb.append("[error opening dir]")
        println(sb.as_view())
        return
    }

    let entries = entries_r.unwrap()
    defer free_entries(&entries)

    for i in 0..entries.len {
        const is_last = i + 1 == entries.len
        const entry_ref: &Entry = &entries[i]

        render_line(prefix, is_last, path, entry_ref, state)

        if entry_ref.kind == FileKind.Dir {
            state.dir_count = state.dir_count + 1

            const can_descend = state.max_depth == 0 or depth + 1 < state.max_depth
            if can_descend {
                let child_path = string_builder(path.len + entry_ref.name.len + 2)
                defer child_path.deinit()
                append_join(&child_path, path, entry_ref.name.as_view())
                ensure_nul_term(&child_path)

                let child_prefix = string_builder(prefix.len + 8)
                defer child_prefix.deinit()
                child_prefix.append(prefix)
                if state.ascii {
                    if is_last { child_prefix.append("    ") } else { child_prefix.append("|   ") }
                } else {
                    if is_last { child_prefix.append("    ") } else { child_prefix.append("│   ") }
                }

                walk(child_path.as_view(), child_prefix.as_view(), depth + 1, state)
            }
        } else {
            state.file_count = state.file_count + 1
        }
    }
}

// -----------------------------------------------------------------------------
// CLI
// -----------------------------------------------------------------------------

fn print_usage() {
    println("Usage: ftree [options] [path ...]")
    println("")
    println("Options:")
    println("  -L, --level N     Descend at most N levels (max-depth)")
    println("  -a, --all         Include hidden entries (names starting with '.')")
    println("  -d, --dirs-only   List directories only")
    println("  -f, --full-path   Print full path prefix for each entry")
    println("  -F, --classify    Append '/' to directory names")
    println("  -s, --size        Show file sizes (bytes) in square brackets")
    println("  -h, --human       Human-readable sizes (K/M/G/T); implies -s")
    println("  -I, --ignore PAT  Exclude entries whose basename matches glob PAT")
    println("      --noreport    Omit the trailing directory/file summary")
    println("      --ascii       Use ASCII instead of Unicode box-drawing")
    println("      --help        Show this help and exit")
}

fn print_summary(state: &State) {
    let sb = string_builder(64)
    defer sb.deinit()
    sb.append(state.dir_count)
    if state.dir_count == 1 { sb.append(" directory, ") } else { sb.append(" directories, ") }
    sb.append(state.file_count)
    if state.file_count == 1 { sb.append(" file") } else { sb.append(" files") }
    println("")
    println(sb.as_view())
}

pub fn main() i32 {
    let argv = get_args()
    defer argv.deinit()

    let state = State {
        max_depth = 0,
        show_hidden = false,
        dirs_only = false,
        full_path = false,
        classify = false,
        show_size = false,
        human_size = false,
        ascii = false,
        no_report = false,
        ignore_pattern = "",
        dir_count = 0,
        file_count = 0,
    }

    let roots: List(String) = list(0)
    defer roots.deinit()

    // getopts doesn't support long-only flags directly, so --help / --ascii /
    // --noreport are dispatched through internal short chars ('?', 'A', 'N')
    // that aren't advertised in the usage text. Users who type `-?`/`-A`/`-N`
    // still work — harmless, and conventional in many CLIs.
    const opts_fmt = "a(all)d(dirs-only)f(full-path)F(classify)s(size)h(human)I(ignore):L(level):?(help)A(ascii)N(noreport)"
    let opts = getopts(opts_fmt, argv.as_slice()[1..])

    for (r in opts) {
        r match {
            Opt('a') => { state.show_hidden = true }
            Opt('d') => { state.dirs_only = true }
            Opt('f') => { state.full_path = true }
            Opt('F') => { state.classify = true }
            Opt('s') => { state.show_size = true }
            Opt('h') => { state.show_size = true; state.human_size = true }
            Opt('A') => { state.ascii = true }
            Opt('N') => { state.no_report = true }
            Opt('?') => { print_usage(); return 0 }
            OptArg('I', pat) => { state.ignore_pattern = pat }
            OptArg('L', val) => {
                const parsed = parse_usize(val)
                if parsed.is_err() {
                    println("ftree: invalid --level value (expected positive integer)")
                    return 2
                }
                const v = parsed.unwrap().0 as usize
                if v == 0 {
                    println("ftree: --level must be at least 1")
                    return 2
                }
                state.max_depth = v
            }
            MissingArg(ch) => {
                print("ftree: missing argument for -")
                println(ch)
                return 2
            }
            Error(_) => {
                println("ftree: unknown option; use --help for usage")
                return 2
            }
            NonOpt(s) => { if s.len > 0 { roots.push(s) } }
            _ => {}
        }
    }

    if roots.len == 0 {
        roots.push(".")
    }

    for ri in 0..roots.len {
        if ri > 0 { println("") }
        const root = roots[ri]
        println(root)
        walk(root, "", 0, &state)
    }

    if !state.no_report {
        print_summary(&state)
    }

    return 0
}
