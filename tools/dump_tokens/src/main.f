// dump_tokens — load a .f file, run the lexer, print the token stream.

import std.env
import std.list
import std.string
import std.string_builder
import flang_parser.lexer

pub fn main() i32 {
    let args = get_args()
    defer args.deinit()
    if args.len < 2 {
        println("usage: dump_tokens <file.f>")
        return 1
    }

    const path = args.as_slice()[1]
    const me = project_info()
    const banner = $"{me.name} {me.version}: {path} (parser {parser_version()})"
    defer banner.deinit()
    println(banner.as_view())

    let src: String = ""
    let lx = lexer(src)
    let tokens = lx.tokenize()
    defer tokens.deinit()

    const count_msg = $"emitted {tokens.len} token(s)"
    defer count_msg.deinit()
    println(count_msg.as_view())
    return 0
}
