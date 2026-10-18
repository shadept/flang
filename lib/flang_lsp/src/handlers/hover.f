// Names no checker table resolves: the compile-time context in a `#if` head, which reads as the
// `core.comptime` declarations, and a generator invocation, which hovers as the `#define` it
// expands and what the expansion declared. The invocation is found in a fresh parse of the analyzed
// text with decl-level `#if` kept as written (`parse_raw`): the analyzed module has it flattened
// away.

import std.collections.dict
import std.collections.list
import std.option
import std.string
import std.string_builder
import std.test

import flang_analysis.analyze
import flang_core.span
import flang_parser.ast
import flang_parser.trivia
import flang_typer.result
import flang_typer.template_expand

import flang_lsp.handlers.syntax_diagnostics
import flang_lsp.query

// A hover answer: `label` renders as code, `doc` as a declaration's docstring, `prose` as markdown
// after both, all over `span`.
pub type ExtraHover = struct {
    label: OwnedString
    doc: OwnedString?
    prose: OwnedString?
    span: SourceSpan
}

pub fn deinit(self: move ExtraHover) {
    self.label.deinit()
    self.doc.deinit()
    self.prose.deinit()
}

pub fn markdown(self: &ExtraHover) OwnedString {
    return hover_markdown(self.label.view, &self.doc, &self.prose)
}

// A hover's markdown: `label` as a flang code block, the docstring `doc` rendered below it, then
// the markdown `prose`.
pub fn hover_markdown(
    label: String,
    doc: &Option(OwnedString),
    prose: &Option(OwnedString),
) OwnedString {
    let md = string_builder(label.len + 32)
    md.append("```flang\n")
    md.append(label)
    md.append("\n```")
    if doc.is_some() {
        const rendered = doc_markdown(doc.unwrap_ref().view)
        md.append("\n\n")
        md.append(rendered.view)
        rendered.deinit()
    }
    if prose.is_some() and prose.unwrap_ref().view.len > 0 {
        md.append("\n\n")
        md.append(prose.unwrap_ref().view)
    }
    const out = md.to_string()
    md.deinit()
    return out
}

// A name of the compile-time context in a `#if` head, resolved to the `core.comptime` declaration
// it reads as: `word` is its span in the text, `decl` the declaration (the struct for a root name,
// the field for a member), `binding` the root's `name: Type` when the word is one.
pub type ComptimeHit = struct {
    word: SourceSpan
    decl: SourceSpan
    binding: String?
}

// The compile-time context's name under `offset` in a `#if` head: `platform` and `runtime` are
// constants of `core.comptime`'s `Platform` and `Runtime`, a member is that struct's field. Null
// for anything else, which the ordinary tiers answer.
pub fn comptime_at(result: &TypeCheckResult, text: String, fid: i32, offset: usize) ComptimeHit? {
    if !in_directive_head(text, offset) {
        return null
    }
    const word = identifier_at(text, offset)
    if word.is_none() {
        return null
    }
    const w = word.unwrap()
    const span = SourceSpan { file_id = fid, start = w.start, length = w.name.len }
    const base = member_base(text, w.start)
    const root = if base.is_some() { base.unwrap() } else { w.name }
    const binding = root match {
        "platform" => "platform: Platform"
        "runtime" => "runtime: Runtime"
        else => return null
    }
    const fqn = if root == "platform" { FQN_PLATFORM } else { FQN_RUNTIME }
    const id = result.nominals.by_fqn.get(fqn)
    if id.is_none() {
        return null
    }
    if base.is_none() {
        return nominal_span(result, id.unwrap()) match {
            Some(d) => Some(ComptimeHit { word = span, decl = d, binding = Some(binding) })
            None => null
        }
    }
    return nominal_field(result, id.unwrap(), w.name) match {
        Some(f) => Some(ComptimeHit { word = span, decl = f.decl_span, binding = null })
        None => null
    }
}

const FQN_PLATFORM: String = "core.comptime.Platform"
const FQN_RUNTIME: String = "core.comptime.Runtime"

// Whether `#if` precedes `offset` on its line with no `{` between: the cursor is in the condition.
fn in_directive_head(text: String, offset: usize) bool {
    let i = if offset + 3 < text.len { offset + 3 } else { text.len }
    while i >= 3 and text[i - 1] != '\n' {
        if text[(i - 3)..i] == "#if" {
            return true
        }
        if text[i - 1] == '{' and i - 1 < offset {
            return false
        }
        i = i - 1
    }
    return false
}

// The name before the `.` that precedes `wstart`, when there is one.
fn member_base(text: String, wstart: usize) String? {
    if wstart < 2 or text[wstart - 1] != '.' {
        return null
    }
    return identifier_at(text, wstart - 2) match {
        Some(b) => Some(b.name)
        None => null
    }
}

// The generator invocation whose `#name` holds `offset` in file `fid`: its `#define` header and
// docstring, and the declarations its expansion added.
pub fn generator_hover(unit: &AnalyzedProject, fid: i32, offset: usize) ExtraHover? {
    const text = unit.sources[fid as usize].view
    let doc = parse_raw(text)
    defer doc.deinit()
    const inv = invocation_at(doc.module.decls.as_slice(), offset)
    if inv.is_none() {
        return null
    }
    const call = inv.unwrap()
    const word = SourceSpan { file_id = fid, start = call.span.start, length = call.name.len + 1 }
    const def = find_define(unit, call.name)
    let names: List(String) = list(4)
    defer names.deinit()
    expansion_names(unit, fid, text, &call, &names)
    let prose = string_builder(64)
    name_list(&prose, "This expansion declares", &names)
    const p = prose.to_string()
    prose.deinit()
    if def.is_none() {
        return Some(.{ label = $"#{call.name}", doc = null, prose = Some(move p), span = word })
    }
    const g = def.unwrap()
    const src = unit.sources[g.file as usize].view
    return Some(.{
        label = from_view(define_header(src, g.span)),
        doc = doc_above(src, g.span.start),
        prose = Some(move p),
        span = word,
    })
}

// `<lead> `a`, `b`.` after whatever `sb` holds; nothing when `names` is empty.
fn name_list(sb: &StringBuilder, lead: String, names: &List(String)) {
    if names.len == 0 {
        return
    }
    if sb.as_view().len > 0 {
        sb.append(" ")
    }
    sb.append(lead)
    sb.append(" ")
    for i in 0..names.len {
        if i > 0 {
            sb.append(", ")
        }
        sb.append("`")
        sb.append(names[i])
        sb.append("`")
    }
    sb.append(".")
}

fn invocation_at(decls: Decl[], offset: usize) GenInvoke? {
    for &d in decls {
        const hit = d.* match {
            GenInvoke(inv) => {
                const word = SourceSpan {
                    file_id = inv.span.file_id,
                    start = inv.span.start,
                    length = inv.name.len + 1,
                }
                if span_contains(word, offset) {
                    Some(inv)
                } else {
                    null
                }
            }
            IfDirective(ifd) => invocation_at(ifd.then_decls, offset)
                ?? invocation_at(ifd.else_decls, offset)
            _ => null
        }
        if hit.is_some() {
            return hit
        }
    }
    return null
}

type DefineAt = struct {
    file: i32
    span: SourceSpan
}

// The `#define` named `name` among the analyzed modules, stdlib included.
fn find_define(unit: &AnalyzedProject, name: String) DefineAt? {
    for i in 0..unit.modules.len {
        for &d in unit.modules[i].decls {
            const hit = d.* match {
                GenDef(g) => if g.name == name { Some(g.span) } else { null }
                _ => null
            }
            if hit.is_some() {
                return Some(DefineAt { file = i as i32, span = hit.unwrap() })
            }
        }
    }
    return null
}

// `#define(name, T: Type)` - the declaration up to its body's brace.
fn define_header(src: String, span: SourceSpan) String {
    let end = span.start + span.length
    if end > src.len {
        end = src.len
    }
    for i in span.start..end {
        if src[i] == '{' {
            end = i
            break
        }
    }
    return trim(src[span.start..end])
}

// The declarations the expansions of `call` appended to file `fid`. Each generated chunk opens with
// a `// #name(args)` header line spelling its invocation.
fn expansion_names(
    unit: &AnalyzedProject,
    fid: i32,
    text: String,
    call: &GenInvoke,
    out: &List(String),
) {
    const header = invocation_header(text, call)
    defer header.deinit()
    const gen_path = generated_path(unit.file_paths[fid as usize].view)
    defer gen_path.deinit()
    for c in unit.modules.len..unit.sources.len {
        if unit.file_paths[c].view != gen_path.view
            or trim(unit.sources[c].view).starts_with(header.view) == false {
            continue
        }
        for &d in unit.modules[fid as usize].decls {
            decl_in_chunk(d, c as i32, out)
        }
    }
}

fn decl_in_chunk(d: &Decl, chunk: i32, out: &List(String)) {
    d.* match {
        Function(f) => if f.span.file_id == chunk { out.push(f.name) }
        Type(t) => if t.span.file_id == chunk { out.push(t.name) }
        Const(c) => if c.span.file_id == chunk { out.push(c.name) }
        _ => {}
    }
}

// `// #name(a, b)`, the arguments as the source spells them.
fn invocation_header(text: String, call: &GenInvoke) OwnedString {
    let sb = string_builder(64)
    sb.append("// #")
    sb.append(call.name)
    sb.append("(")
    for i in 0..call.args.len {
        if i > 0 {
            sb.append(", ")
        }
        const span = call.args[i] match {
            IdentArg(a) => a.span
            TypeArg(t) => type_expr_span(&t)
        }
        sb.append(text[span.start..(span.start + span.length)])
    }
    sb.append(")")
    const out = sb.to_string()
    sb.deinit()
    return out
}

// Tests

test "define_header stops at the body brace" {
    const src = "#define(derive, T: Type, ..Traits: Ident) {\n    body\n}\n"
    const span = SourceSpan { file_id = 0, start = 0, length = src.len }
    assert_eq(define_header(src, span), "#define(derive, T: Type, ..Traits: Ident)", "header only")
}
