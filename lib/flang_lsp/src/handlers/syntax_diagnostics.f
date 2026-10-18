// Parse-only diagnostics for one buffer: the per-keystroke feature, and the parse step the other
// parse-derived handlers share. Fast enough to run on every didChange (a parse is milliseconds), so
// nothing is cached; each call parses fresh from the text it is given.
//
// The returned Module views into `text`; a ParsedDoc must be dropped before the buffer it was
// parsed from.

import std.allocator
import std.collections.list
import std.test

import flang_core.diagnostic
import flang_parser.ast
import flang_parser.comptime
import flang_parser.cst
import flang_parser.lexer
import flang_parser.parser
import flang_parser.projector

pub type ParsedDoc = struct {
    module: Module
    diagnostics: List(Diagnostic)
}

pub fn deinit(self: move ParsedDoc) {
    self.diagnostics.deinit()
    self.module.deinit()
}

// Lex, parse and project one buffer. Decl-level #if resolves against the host context, matching
// what a build of this machine would compile.
pub fn parse_doc(text: String) ParsedDoc {
    let diagnostics: List(Diagnostic) = list(0)
    let lx = lexer(text)
    let tokens = lx.tokenize()
    let p = parser(tokens, text)
    let cst = p.tree.node_at(p.parse_module())
    let module = project_module(cst, 0i32, Some(&diagnostics))
    const cctx = host_ctx()
    flatten_module_decls(&module, &cctx, &diagnostics)
    for d in p.diagnostics.drain() {
        diagnostics.push(d)
    }
    p.deinit()
    return .{ module = move module, diagnostics = move diagnostics }
}

// Tests

test "a parse error surfaces as a diagnostic with a span" {
    let doc = parse_doc("fn broken( {\n")
    defer doc.deinit()
    assert_true(doc.diagnostics.len > 0, "parse error reported")
}
