// textDocument/documentSymbol: the outline of one parsed module - top-level declarations, with
// struct fields and enum variants as children. Needs no types, so it serves from a fresh parse of
// the open buffer (handlers.syntax_diagnostics).

import std.allocator
import std.list
import std.string
import std.string_builder
import std.test
import flang_core.span
import flang_parser.ast
import flang_lsp.handlers.syntax_diagnostics

// LSP SymbolKind, tagged with the protocol's fixed numbering; `kind as i64` is the wire value.
pub type SymbolKind = enum {
    Class = 5
    Field = 8
    Enum = 10
    Function = 12
    Constant = 14
    EnumMember = 22
    Struct = 23
}

// One outline entry: a top-level declaration, with struct fields and enum variants as children.
pub type DocSymbol = struct {
    name: OwnedString
    kind: SymbolKind
    span: SourceSpan
    children: List(DocSymbol)
}

pub fn deinit(self: &DocSymbol) {
    self.children.deinit()
    self.name.deinit()
}

pub fn document_symbols(m: &Module, allocator: &Allocator? = null) List(DocSymbol) {
    let out: List(DocSymbol) = list(0, allocator)
    for d in m.decls {
        d match {
            Function(f) => out.push(leaf(f.name, SymbolKind.Function, f.span, allocator))
            Const(c) => out.push(leaf(c.name, SymbolKind.Constant, c.span, allocator))
            Type(t) => out.push(type_symbol(&t, allocator))
            Test(t) => {
                // `label` is the raw string-literal token, quotes included.
                const label = $"test {t.label}"
                defer label.deinit()
                out.push(leaf(label.as_view(), SymbolKind.Function, t.span, allocator))
            }
            GenDef(g) => {
                const label = $"#{g.name}"
                defer label.deinit()
                out.push(leaf(label.as_view(), SymbolKind.Function, g.span, allocator))
            }
            _ => {}
        }
    }
    return out
}

fn leaf(name: String, kind: SymbolKind, span: SourceSpan, alloc: &Allocator?) DocSymbol {
    return .{
        name = from_view(name, alloc),
        kind = kind,
        span = span,
        children = list(0, alloc),
    }
}

fn type_symbol(t: &TypeDecl, alloc: &Allocator?) DocSymbol {
    t.body match {
        AnonStruct(st) => {
            let children: List(DocSymbol) = list(st.fields.len, alloc)
            for &f in st.fields {
                children.push(leaf(f.name, SymbolKind.Field, f.span, alloc))
            }
            let sym = leaf(t.name, SymbolKind.Struct, t.span, alloc)
            sym.children.deinit()
            sym.children = children
            return sym
        }
        AnonEnum(en) => {
            let children: List(DocSymbol) = list(en.variants.len, alloc)
            for &v in en.variants {
                children.push(leaf(v.name, SymbolKind.EnumMember, v.span, alloc))
            }
            let sym = leaf(t.name, SymbolKind.Enum, t.span, alloc)
            sym.children.deinit()
            sym.children = children
            return sym
        }
        else => {}
    }
    return leaf(t.name, SymbolKind.Class, t.span, alloc)
}

// Tests

test "a single-line struct decl keeps its fields in the outline" {
    let doc = parse_doc("pub type P = struct { x: i32\n y: i32 }\n")
    let found = false
    for d in doc.module.decls {
        d match {
            Type(t) => {
                found = true
                t.body match {
                    AnonStruct(st) => assert_eq(st.fields.len, 2 as usize, "fields parsed")
                    else => assert_true(false, "body is not AnonStruct")
                }
            }
            _ => {}
        }
    }
    assert_true(found, "type decl projected")

    let syms = document_symbols(&doc.module)
    assert_eq(syms.len, 1 as usize, "one symbol")
    assert_eq(syms[0].kind as i64, SymbolKind.Struct as i64, "struct kind")
    assert_eq(syms[0].children.len, 2 as usize, "children carried")
    syms.deinit()
    doc.deinit()
}

test "document symbols cover functions, types, consts and tests" {
    const src = "import std.list\npub fn go(x: i32) i32 { return x }\npub type P = struct { x: i32\n y: i32 }\npub type E = enum { A\n B(i32) }\npub type Alias = i32?\nconst N: i32 = 3\ntest \"works\" { }\n"
    let doc = parse_doc(src)
    defer doc.deinit()
    assert_eq(doc.diagnostics.len, 0 as usize, "clean parse")

    let syms = document_symbols(&doc.module)
    defer syms.deinit()
    assert_eq(syms.len, 6 as usize, "import excluded, six symbols")
    assert_eq(syms[0].name.as_view(), "go", "function name")
    assert_eq(syms[0].kind as i64, SymbolKind.Function as i64, "function kind")
    assert_eq(syms[1].name.as_view(), "P", "struct name")
    assert_eq(syms[1].children.len, 2 as usize, "struct fields as children")
    assert_eq(syms[1].children[0].name.as_view(), "x", "field name")
    assert_eq(syms[1].children[0].kind as i64, SymbolKind.Field as i64, "field kind")
    assert_eq(syms[2].kind as i64, SymbolKind.Enum as i64, "enum kind")
    assert_eq(syms[2].children[1].name.as_view(), "B", "variant name")
    assert_eq(syms[2].children[1].kind as i64, SymbolKind.EnumMember as i64, "variant kind")
    assert_eq(syms[3].kind as i64, SymbolKind.Class as i64, "alias kind")
    assert_eq(syms[4].kind as i64, SymbolKind.Constant as i64, "const kind")
    assert_eq(syms[5].name.as_view(), "test \"works\"", "test label")
}
