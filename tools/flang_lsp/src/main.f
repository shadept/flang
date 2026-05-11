// flang_lsp — the FLang language server.
//
// Wraps flang_parser + the bootstrap compiler's query graph behind a
// JSON-RPC LSP frame, exposes hover, goto-def, find-references, inlay
// hints, formatting (via flang_fmt's library entry point), and code
// actions sourced from flang_core.
//
// Doc-comment surfacing: leading `//` comments immediately preceding a
// declaration are first-class doc comments. The LSP extracts them on
// hover so type definitions like `Trivia` and `TokenKind` from
// flang_parser show their authored documentation in the editor.

import std.env
import std.string
import std.string_builder
import flang_parser.lexer
import flang_core.diagnostic

pub fn main() i32 {
    const me = project_info()
    const banner = $"{me.name} {me.version} (parser {parser_version()})"
    defer banner.deinit()
    println(banner.as_view())
    println("LSP entry point — JSON-RPC loop not yet implemented.")
    return 0
}
