// textDocument/documentSymbol: the outline of one parsed module - top-level declarations, with
// struct fields and enum variants as children. Needs no types, so it serves from a fresh parse of
// the open buffer (handlers.syntax_diagnostics).

import std.allocator
import std.collections.list
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

pub fn deinit(self: move DocSymbol) {
    self.children.deinit()
    self.name.deinit()
}

pub fn document_symbols(m: &Module) List(DocSymbol) {
    let out: List(DocSymbol) = list(0)
    for &d in m.decls {
        d.* match {
            Function(f) => out.push(leaf(f.name, SymbolKind.Function, f.span))
            Const(c) => out.push(leaf(c.name, SymbolKind.Constant, c.span))
            Context(c) => out.push(leaf(c.name, SymbolKind.Field, c.span))
            Type(t) => out.push(type_symbol(&t))
            Test(t) => {
                // Quoted for display, mirroring the declaration: `label` is the literal's value,
                // and a label with spaces in it needs the delimiters to read as one name.
                const label = $"test \"{t.label}\""
                defer label.deinit()
                out.push(leaf(label.view, SymbolKind.Function, t.span))
            }
            GenDef(g) => {
                const label = $"#{g.name}"
                defer label.deinit()
                out.push(leaf(label.view, SymbolKind.Function, g.span))
            }
            _ => {}
        }
    }
    return out
}

fn leaf(name: String, kind: SymbolKind, span: SourceSpan) DocSymbol {
    return .{ name = from_view(name), kind = kind, span = span, children = list(0) }
}

fn type_symbol(t: &TypeDecl) DocSymbol {
    t.body match {
        AnonStruct(st) => {
            let children: List(DocSymbol) = list(st.fields.len)
            for &f in st.fields {
                children.push(leaf(f.name, SymbolKind.Field, f.span))
            }
            let sym = leaf(t.name, SymbolKind.Struct, t.span)
            install(&sym.children, children)
            return sym
        }
        AnonEnum(en) => {
            let children: List(DocSymbol) = list(en.variants.len)
            for &v in en.variants {
                children.push(leaf(v.name, SymbolKind.EnumMember, v.span))
            }
            let sym = leaf(t.name, SymbolKind.Enum, t.span)
            install(&sym.children, children)
            return sym
        }
        else => {}
    }
    return leaf(t.name, SymbolKind.Class, t.span)
}

// Tests

test "a single-line struct decl keeps its fields in the outline" {
    let doc = parse_doc("pub type P = struct { x: i32\n y: i32 }\n")
    let found = false
    for &d in doc.module.decls {
        d.* match {
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
    assert_eq(syms[0].name.view, "go", "function name")
    assert_eq(syms[0].kind as i64, SymbolKind.Function as i64, "function kind")
    assert_eq(syms[1].name.view, "P", "struct name")
    assert_eq(syms[1].children.len, 2 as usize, "struct fields as children")
    assert_eq(syms[1].children[0].name.view, "x", "field name")
    assert_eq(syms[1].children[0].kind as i64, SymbolKind.Field as i64, "field kind")
    assert_eq(syms[2].kind as i64, SymbolKind.Enum as i64, "enum kind")
    assert_eq(syms[2].children[1].name.view, "B", "variant name")
    assert_eq(syms[2].children[1].kind as i64, SymbolKind.EnumMember as i64, "variant kind")
    assert_eq(syms[3].kind as i64, SymbolKind.Class as i64, "alias kind")
    assert_eq(syms[4].kind as i64, SymbolKind.Constant as i64, "const kind")
    assert_eq(syms[5].name.view, "test \"works\"", "test label")
}
