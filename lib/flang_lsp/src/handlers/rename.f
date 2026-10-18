// textDocument/rename and prepareRename over one analyzed project: the symbol a cursor names, its
// declaration and every reference the checker recorded for it. The server resolves the symbol in
// each open project that loads the declaring file and merges the edits by file.
//
// A reference span is often wider than the name it spells (`E.A`, `xs.push(v)`, a whole `const`
// declaration), so each span is narrowed to the name by `name_offset`. Generated code is never
// edited: renaming a type renames the generator arguments that name it instead, and the next
// expansion follows.

import std.collections.dict
import std.collections.list
import std.option
import std.string
import std.test

import flang_analysis.analyze
import flang_core.span
import flang_parser.ast
import flang_parser.lexer
import flang_parser.token
import flang_typer.function_registry
import flang_typer.inference_results
import flang_typer.node_id
import flang_typer.nominal_registry
import flang_typer.reporter
import flang_typer.result
import flang_typer.specialization
import flang_typer.type
import flang_typer.well_known

import flang_lsp.handlers.inlay_hint
import flang_lsp.query

// A renameable symbol: the target its references resolve to (null for a binder nothing reads) and
// its declaration's name span.
pub type Symbol = struct {
    target: ResolvedTarget?
    decl: SourceSpan
}

// Whether `name` lexes as exactly one identifier: no keyword, no `#`, no surrounding space.
pub fn is_identifier(name: String) bool {
    let lx = lexer(name)
    defer lx.deinit()
    const first = lx.next_token()
    const second = lx.next_token()
    const whole = first.text.len == name.len
    return first.kind == TokenKind.Identifier and whole and second.kind == TokenKind.Eof
}

// Where `name` is spelled inside `span` of `text`. A reference spells it at its start (a read, a
// pattern, a field), else as the first member `.name` outside brackets (`E.A`, `xs.push(v)`), else
// as the first bare word outside brackets; a declaration (`decl`) spells it as that bare word,
// after its keywords. Null when the span does not spell it (`Self` naming a struct).
pub fn name_offset(text: String, span: SourceSpan, name: String, decl: bool) usize? {
    const end = if span.start + span.length > text.len { text.len } else { span.start + span.length }
    if !decl and is_word_at(text, span.start, end, name) {
        return Some(span.start)
    }
    let member: usize? = null
    let bare: usize? = null
    let depth: i32 = 0
    for i in span.start..end {
        depth = depth + bracket_delta(text[i])
        if depth != 0 or !is_word_at(text, i, end, name) {
            continue
        }
        const after_dot = i > 0 and text[i - 1] == '.'
        if after_dot and member.is_none() {
            member = Some(i)
        }
        if !after_dot and bare.is_none() {
            bare = Some(i)
        }
    }
    if decl {
        return bare
    }
    return member ?? bare
}

fn bracket_delta(c: u8) i32 {
    return c match {
        '(' | '[' | '{' => 1
        ')' | ']' | '}' => -1
        else => 0
    }
}

// `name` as a whole word at `i`, ending by `end`. A `#` before it makes it a template name.
fn is_word_at(text: String, i: usize, end: usize, name: String) bool {
    const stop = i + name.len
    if stop > end or text[i..stop] != name {
        return false
    }
    const open_before = i == 0 or (!is_ident_char(text[i - 1]) and text[i - 1] != '#')
    const open_after = stop == text.len or !is_ident_char(text[stop])
    return open_before and open_after
}

// The symbol whose name starts at `wstart` in file `fid`: a reference the checker resolved, else a
// declaration's own name. Null when the word names nothing renameable.
pub fn symbol_at(unit: &AnalyzedProject, fid: i32, wstart: usize, name: String) Symbol? {
    const used = used_symbol(unit, fid, wstart, name)
    if used.is_some() {
        return used
    }
    return declared_symbol(unit, fid, wstart, name)
}

fn used_symbol(unit: &AnalyzedProject, fid: i32, wstart: usize, name: String) Symbol? {
    const result = &unit.result
    const hit = target_at(result, fid, wstart)
    if hit.is_none() {
        return null
    }
    const target = canonical(result, hit.unwrap().target)
    const full = target_decl_span(result, &target)
    if full.is_none() {
        return null
    }
    const span = hit.unwrap().span
    const at = name_offset(source_of(unit, fid), span, name, same_span(span, full.unwrap()))
    const on_name = at match {
        Some(o) => o == wstart
        None => false
    }
    if !on_name {
        return null
    }
    return decl_name(unit, full.unwrap(), name) match {
        Some(d) => Some(Symbol { target = Some(target), decl = d })
        None => null
    }
}

// A specialization's references are its generic template's.
fn canonical(result: &TypeCheckResult, t: ResolvedTarget) ResolvedTarget {
    return t match {
        RtSpecialized(sid) => result.specializations.find(sid) match {
            Some(s) => ResolvedTarget.RtFunction(s.function_id)
            None => t
        }
        _ => t
    }
}

fn source_of(unit: &AnalyzedProject, fid: i32) String {
    return unit.sources[fid as usize].view
}

fn same_span(a: SourceSpan, b: SourceSpan) bool {
    return a.file_id == b.file_id and a.start == b.start and a.length == b.length
}

// The name span inside the declaration spanning `full`.
fn decl_name(unit: &AnalyzedProject, full: SourceSpan, name: String) SourceSpan? {
    if full.file_id < 0 or full.file_id as usize >= unit.sources.len {
        return null
    }
    return name_offset(source_of(unit, full.file_id), full, name, true) match {
        Some(o) => Some(SourceSpan { file_id = full.file_id, start = o, length = name.len })
        None => null
    }
}

// Whether the declaration spanning `full` names itself at `want`.
fn names_at(unit: &AnalyzedProject, full: SourceSpan, name: String, want: SourceSpan) bool {
    if full.file_id != want.file_id or !span_contains(full, want.start) {
        return false
    }
    return decl_name(unit, full, name) match {
        Some(d) => same_span(d, want)
        None => false
    }
}

// A declaration whose own name sits at `wstart`: a function, a nominal type or one of its members,
// a binding someone reads, or a binder nobody does.
fn declared_symbol(unit: &AnalyzedProject, fid: i32, wstart: usize, name: String) Symbol? {
    const want = SourceSpan { file_id = fid, start = wstart, length = name.len }
    const target = function_named(unit, name, want) ?? nominal_named(unit, name, want)
        ?? local_named(unit, name, want)
    if target.is_some() {
        return Some(Symbol { target = target, decl = want })
    }
    if fid as usize >= unit.modules.len {
        return null
    }
    let binders = module_binders(&unit.modules[fid as usize])
    defer binders.deinit()
    for &b in binders {
        if b.name == name and names_at(unit, b.name_span, name, want) {
            return Some(Symbol { target = null, decl = want })
        }
    }
    return null
}

fn function_named(unit: &AnalyzedProject, name: String, want: SourceSpan) ResolvedTarget? {
    const overloads = unit.result.functions.by_name.get_ref(name)
    if overloads.is_none() {
        return null
    }
    for &s in overloads.unwrap() {
        if !s.retired and names_at(unit, s.decl_span, name, want) {
            return Some(ResolvedTarget.RtFunction(s.id))
        }
    }
    return null
}

// A struct or enum declared at `want`, or one of its fields or variants. A field of the runtime
// context's struct is a context field, which its uses resolve to by FQN.
fn nominal_named(unit: &AnalyzedProject, name: String, want: SourceSpan) ResolvedTarget? {
    const result = &unit.result
    for entry in result.nominals.by_fqn.iter() {
        const id = entry.value
        const def = result.nominals.find(id)
        if def.is_none() {
            continue
        }
        const hit = def.unwrap().* match {
            NomStruct(sd) => struct_member(unit, id, &sd, name, want)
            NomEnum(ed) => enum_member(unit, id, &ed, name, want)
        }
        if hit.is_some() {
            return hit
        }
    }
    return null
}

fn struct_member(
    unit: &AnalyzedProject,
    id: NominalId,
    sd: &StructDef,
    name: String,
    want: SourceSpan,
) ResolvedTarget? {
    if short_name(sd.fqn) == name and names_at(unit, sd.decl_span, name, want) {
        return Some(ResolvedTarget.RtType(node_id_of(sd.decl_span)))
    }
    for i in 0..sd.fields.len {
        const f = &sd.fields[i]
        if f.name != name or !names_at(unit, f.decl_span, name, want) {
            continue
        }
        const ctx_fields = &unit.result.context_fields
        if sd.fqn == FQN_CONTEXT and i < ctx_fields.len {
            return Some(ResolvedTarget.RtContextField(ctx_fields[i].view))
        }
        return Some(ResolvedTarget.RtStructField(id, i as u32))
    }
    return null
}

fn enum_member(
    unit: &AnalyzedProject,
    id: NominalId,
    ed: &EnumDef,
    name: String,
    want: SourceSpan,
) ResolvedTarget? {
    if short_name(ed.fqn) == name and names_at(unit, ed.decl_span, name, want) {
        return Some(ResolvedTarget.RtType(node_id_of(ed.decl_span)))
    }
    for i in 0..ed.variants.len {
        const v = &ed.variants[i]
        if v.name == name and names_at(unit, v.decl_span, name, want) {
            return Some(ResolvedTarget.RtEnumVariant(id, i as u32))
        }
    }
    return null
}

// A local or type parameter declared at `want` that some reference resolves to.
fn local_named(unit: &AnalyzedProject, name: String, want: SourceSpan) ResolvedTarget? {
    const result = &unit.result
    for e in result.resolved_targets.iter() {
        if binds_at(unit, e.value, name, want) {
            return Some(e.value)
        }
    }
    for s in result.specializations.specs.iter() {
        for e in s.value.overlay.resolved_targets.iter() {
            if binds_at(unit, e.value, name, want) {
                return Some(e.value)
            }
        }
    }
    return null
}

fn binds_at(unit: &AnalyzedProject, t: ResolvedTarget, name: String, want: SourceSpan) bool {
    const decl = t match {
        RtLocal(n) => n
        RtType(n) => n
        _ => return false
    }
    return span_of_node(&unit.result, decl) match {
        Some(full) => names_at(unit, full, name, want)
        None => false
    }
}

// Every span to rewrite for `sym` in this project: its declaration, then each reference in a real
// source file narrowed to the name. A type also renames the generator arguments that name it.
pub fn symbol_edits(unit: &AnalyzedProject, sym: &Symbol, name: String) List(SourceSpan) {
    let out: List(SourceSpan) = list(8)
    out.push(sym.decl)
    if sym.target.is_none() {
        return out
    }
    const target = sym.target.unwrap()
    const result = &unit.result
    const full = target_decl_span(result, &target)
    for e in result.resolved_targets.iter() {
        if refers(result, &e.value, &target) {
            add_ref(unit, &out, result.get_span(e.key), name, full)
        }
    }
    for s in result.specializations.specs.iter() {
        const o = &s.value.overlay
        for e in o.resolved_targets.iter() {
            if refers(result, &e.value, &target) {
                add_ref(unit, &out, o.spans.get(e.key), name, full)
            }
        }
    }
    if names_nominal(result, &target) {
        generator_args(unit, name, &out)
    }
    return out
}

fn refers(result: &TypeCheckResult, t: &ResolvedTarget, target: &ResolvedTarget) bool {
    if same_target(t, target) {
        return true
    }
    const fid = target.* match {
        RtFunction(id) => id
        _ => return false
    }
    return t.* match {
        RtSpecialized(sid) => result.specializations.find(sid) match {
            Some(s) => s.function_id == fid
            None => false
        }
        _ => false
    }
}

// The name inside reference `span`, when the span is in one of the project's loaded files (not a
// generated chunk) and spells it.
fn add_ref(
    unit: &AnalyzedProject,
    out: &List(SourceSpan),
    span: SourceSpan?,
    name: String,
    full: SourceSpan?,
) {
    if span.is_none() {
        return
    }
    const s = span.unwrap()
    if s.file_id < 0 or s.file_id as usize >= unit.modules.len {
        return
    }
    const is_decl = full match {
        Some(f) => same_span(f, s)
        None => false
    }
    const at = name_offset(source_of(unit, s.file_id), s, name, is_decl)
    if at.is_some() {
        push_unique(out, SourceSpan { file_id = s.file_id, start = at.unwrap(), length = name.len })
    }
}

// Whether `target` is a struct or enum declaration rather than a type parameter.
pub fn names_nominal(result: &TypeCheckResult, target: &ResolvedTarget) bool {
    const decl = target.* match {
        RtType(n) => n
        _ => return false
    }
    for entry in result.nominals.by_fqn.iter() {
        const span = nominal_span(result, entry.value)
        if span.is_some() and node_id_of(span.unwrap()) == decl {
            return true
        }
    }
    return false
}

// Generator invocation arguments spelled `name` in the project's own files: `#derive(P, eq)`
// expands from them, so they rename with the type.
fn generator_args(unit: &AnalyzedProject, name: String, out: &List(SourceSpan)) {
    for fid in 0..unit.modules.len {
        if fid >= unit.project_origin.len or !unit.project_origin[fid] {
            continue
        }
        for &d in unit.modules[fid].decls {
            d.* match {
                GenInvoke(inv) => invocation_args(&inv, name, out)
                _ => {}
            }
        }
    }
}

fn invocation_args(inv: &GenInvoke, name: String, out: &List(SourceSpan)) {
    for &a in inv.args {
        const span: SourceSpan? = a.* match {
            IdentArg(ia) => if ia.name == name { Some(ia.span) } else { null }
            TypeArg(te) => te match {
                Named(n) => if n.name == name and n.generic_args.len == 0 { Some(n.span) }
                else { null }
                _ => null
            }
        }
        if span.is_some() {
            const s = span.unwrap()
            push_unique(out, SourceSpan { file_id = s.file_id, start = s.start, length = name.len })
        }
    }
}

// Whether the symbol binds a C name through `#foreign`, which a rename would break.
pub fn is_foreign_symbol(result: &TypeCheckResult, sym: &Symbol) bool {
    if sym.target.is_none() {
        return false
    }
    return sym.target.unwrap() match {
        RtFunction(id) => result.functions.find_by_id(id) match {
            Some(s) => s.is_foreign
            None => false
        }
        RtType(n) => foreign_nominal(result, n)
        _ => false
    }
}

fn foreign_nominal(result: &TypeCheckResult, decl: NodeId) bool {
    for entry in result.nominals.by_fqn.iter() {
        const def = result.nominals.find(entry.value)
        if def.is_none() {
            continue
        }
        const hit = def.unwrap().* match {
            NomStruct(sd) => sd.is_foreign and node_id_of(sd.decl_span) == decl
            NomEnum(_) => false
        }
        if hit {
            return true
        }
    }
    return false
}

// Tests

test "is_identifier accepts names and refuses keywords, templates and junk" {
    assert_true(is_identifier("point"), "a plain name")
    assert_true(is_identifier("_tmp2"), "underscore-led")
    assert_true(!is_identifier("match"), "a keyword")
    assert_true(!is_identifier("#gen"), "a template name")
    assert_true(!is_identifier("two words"), "two tokens")
    assert_true(!is_identifier(" pad"), "surrounding space")
    assert_true(!is_identifier("9lives"), "digit-led")
    assert_true(!is_identifier(""), "empty")
}

fn at(text: String, start: usize, len: usize, name: String, decl: bool) usize? {
    return name_offset(text, SourceSpan { file_id = 0, start = start, length = len }, name, decl)
}

test "name_offset narrows a reference to the name it spells" {
    const t = "x.push(y.push(z))"
    assert_eq(at(t, 0, t.len, "push", false).unwrap(), 2 as usize, "outer member, not the nested")
    assert_eq(at("E.A", 0, 3, "A", false).unwrap(), 2 as usize, "qualified variant")
    assert_eq(at("Some(x)", 0, 7, "Some", false).unwrap(), 0 as usize, "a pattern spells it first")
    assert_eq(at("f(a).len", 0, 8, "len", false).unwrap(), 5 as usize, "receiver call skipped")
    assert_true(at("Self", 0, 4, "P", false).is_none(), "`Self` does not spell the type")
    assert_true(at("#gen(x)", 0, 7, "gen", false).is_none(), "a template name is not the word")
}

test "name_offset finds a declaration's name after its keywords" {
    const f = "pub fn point(q: i32) i32 { return point(q) }"
    assert_eq(at(f, 0, f.len, "point", true).unwrap(), 7 as usize, "the declared name")
    const t = "pub type P = struct { next: &P }"
    assert_eq(at(t, 0, t.len, "P", true).unwrap(), 9 as usize, "not the self-reference")
    const c = "const N: i32 = M.N"
    assert_eq(at(c, 0, c.len, "N", true).unwrap(), 6 as usize, "not a member read in the value")
}
