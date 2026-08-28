// ModuleIndex: one module's declared symbols, flattened for name-level search. Pointer-free - owned
// strings and SourceSpans only - so it outlives re-parses of the AST it was built from. Serves
// cross-file, name-level queries (workspace/symbol); cursor-level and type-level queries go to the
// checker, never here.

import std.allocator
import std.list
import std.string
import std.test
import flang_core.span
import flang_parser.ast
import flang_lsp.handlers.document_symbol
import flang_lsp.handlers.syntax_diagnostics

pub type IndexSymbol = struct {
    name: OwnedString
    // The enclosing declaration's name for members (struct fields, enum variants), empty for
    // top-level declarations.
    container: OwnedString
    kind: SymbolKind
    span: SourceSpan
}

pub fn deinit(self: &IndexSymbol) {
    self.name.deinit()
    self.container.deinit()
}

pub type ModuleIndex = struct {
    symbols: List(IndexSymbol)
}

pub fn deinit(self: &ModuleIndex) {
    self.symbols.deinit()
}

// Build the index for one parsed module: the documentSymbol outline, flattened, members keeping
// their container's name.
pub fn module_index(m: &Module, allocator: &Allocator? = null) ModuleIndex {
    let tree = document_symbols(m, allocator)
    let symbols: List(IndexSymbol) = list(tree.len, allocator)
    for &s in tree {
        flatten(&symbols, s, "", allocator)
    }
    tree.deinit()
    return .{ symbols = symbols }
}

fn flatten(out: &List(IndexSymbol), s: &DocSymbol, container: String, alloc: &Allocator?) {
    out.push(.{
        name = from_view(s.name.as_view(), alloc),
        container = from_view(container, alloc),
        kind = s.kind,
        span = s.span,
    })
    for &c in s.children {
        flatten(out, c, s.name.as_view(), alloc)
    }
}

// ASCII case-insensitive substring test; the empty query matches everything. The client does its
// own fuzzy ranking on top, so substring is the server's whole contract.
pub fn symbol_matches(name: String, query: String) bool {
    if query.len == 0 {
        return true
    }
    if query.len > name.len {
        return false
    }
    for i in 0..(name.len - query.len + 1) {
        if eq_ignore_ascii_case(name[i..(i + query.len)], query) {
            return true
        }
    }
    return false
}

// Tests

test "module_index flattens members under their container" {
    let doc = parse_doc("pub fn go() i32 { return 1 }\npub type P = struct { x: i32 }\n")
    defer doc.deinit()
    let idx = module_index(&doc.module)
    defer idx.deinit()

    assert_eq(idx.symbols.len, 3 as usize, "function, struct, field")
    assert_eq(idx.symbols[0].name.as_view(), "go", "function first")
    assert_eq(idx.symbols[0].container.as_view(), "", "top-level has no container")
    assert_eq(idx.symbols[1].name.as_view(), "P", "struct follows")
    assert_eq(idx.symbols[2].name.as_view(), "x", "field flattened after its struct")
    assert_eq(idx.symbols[2].container.as_view(), "P", "field carries its container")
    assert_eq(idx.symbols[2].kind as i64, SymbolKind.Field as i64, "field kind preserved")
}

test "symbol_matches is a case-insensitive substring test" {
    assert_true(symbol_matches("OpenProject", "open"), "prefix, case-folded")
    assert_true(symbol_matches("OpenProject", "PROJ"), "infix, case-folded")
    assert_true(symbol_matches("x", ""), "empty query matches everything")
    assert_true(!symbol_matches("go", "gone"), "query longer than the name cannot match")
    assert_true(!symbol_matches("alpha", "bet"), "no occurrence, no match")
}
