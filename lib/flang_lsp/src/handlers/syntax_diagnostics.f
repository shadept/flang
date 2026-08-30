// Parse-only diagnostics for one buffer: the per-keystroke feature, and the parse step the other
// parse-derived handlers share. Fast enough to run on every didChange (a parse is milliseconds), so
// nothing is cached; each call parses fresh from the text it is given.
//
// The returned Module views into `text`; a ParsedDoc must be dropped before the buffer it was
// parsed from.

import std.allocator
import std.list
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

pub fn deinit(self: &ParsedDoc) {
    self.diagnostics.deinit()
    self.module.deinit()
}

// Lex, parse and project one buffer. Decl-level #if resolves against the host context, matching
// what a build of this machine would compile.
pub fn parse_doc(text: String, allocator: &Allocator? = null) ParsedDoc {
    let diagnostics: List(Diagnostic) = list(0, allocator)
    let lx = lexer(text, allocator)
    let tokens = lx.tokenize()
    let p = parser(tokens, text, allocator)
    let cst = p.tree.node_at(p.parse_module())
    let module = project_module(cst, 0i32, allocator)
    const cctx = host_ctx()
    flatten_module_decls(&module, &cctx, &diagnostics, allocator)
    const taken = p.diagnostics.to_owned_slice()
    diagnostics.push_all(taken.0)
    taken.1.free(taken.0)
    p.deinit()
    return .{ module = module, diagnostics = diagnostics }
}

// Tests

test "a parse error surfaces as a diagnostic with a span" {
    let doc = parse_doc("fn broken( {\n")
    defer doc.deinit()
    assert_true(doc.diagnostics.len > 0, "parse error reported")
}
