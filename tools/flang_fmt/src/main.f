// flang_fmt — FLang source formatter.
//
// Walks the CST produced by flang_parser, rewrites trivia under a fixed
// style policy, re-emits source. The lossless CST guarantees round-trip
// fidelity on files the formatter chooses not to touch.

import std.env
import std.list
import std.string
import std.string_builder
import flang_parser.lexer
import flang_core.diagnostic

pub fn main() i32 {
    let args = get_args()
    defer args.deinit()
    if args.len < 2 {
        println("usage: flang_fmt <file.f> [...]")
        return 1
    }

    const me = project_info()
    const banner = $"{me.name} {me.version} (parser {parser_version()})"
    defer banner.deinit()
    println(banner.as_view())

    let argv = args.as_slice()
    for i in 1..argv.len {
        const path = argv[i]
        const msg = $"  would format: {path}"
        defer msg.deinit()
        println(msg.as_view())
    }
    return 0
}
