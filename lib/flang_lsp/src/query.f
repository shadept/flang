// Cursor-level queries over an analyzed project's TypeCheckResult - the data behind hover,
// definition, typeDefinition and references. The checker records the span of every node it touched
// (`result.spans`), so "the node at the cursor" is the innermost recorded span containing the
// offset that has an entry in the table the query needs - no AST walk. Cursor-level and type-level
// answers come from here; name-level fallbacks (type names, templates) go to the ModuleIndex.

import std.allocator
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import std.test
import flang_core.span
import flang_analysis.analyze
import flang_typer.function_registry
import flang_typer.inference_results
import flang_typer.interner
import flang_typer.node_id
import flang_typer.nominal_registry
import flang_typer.reporter
import flang_typer.result
import flang_typer.type

// The file id of `path` inside `unit`, by exact path comparison (both sides use the resolver's path
// convention).
pub fn file_id_of(unit: &AnalyzedProject, path: String) i32? {
    for i in 0..unit.file_paths.len {
        if unit.file_paths[i].as_view() == path {
            return Some(i as i32)
        }
    }
    return null
}

pub fn span_contains(span: SourceSpan, offset: usize) bool {
    return offset >= span.start and offset < span.start + span.length
}

// A generic template's body is checked only per instantiation, into that specialization's private
// overlay (checker.f `check_one_decl`) - the base tables hold nothing for its nodes. So every
// cursor query scans the base tables first and falls through to the overlays; the first overlay
// holding the node answers, so inside a generic body types are one concrete instantiation's.

pub type TypedHit = struct {
    node: NodeId
    span: SourceSpan
    ty: Ty
}

// The innermost node at `offset` with a recorded type. Linear over the span tables; a project's are
// tens of thousands of entries, well under a millisecond per request.
pub fn typed_at(result: &TypeCheckResult, fid: i32, offset: usize) TypedHit? {
    let best: TypedHit? = null
    let best_len: usize = 0
    for e in result.spans.iter() {
        const span = e.value
        if span.file_id != fid or !span_contains(span, offset) {
            continue
        }
        const ty = result.get_type(e.key)
        if ty.is_none() {
            continue
        }
        if best.is_none() or span.length < best_len {
            best = Some(TypedHit { node = e.key, span = span, ty = ty.unwrap() })
            best_len = span.length
        }
    }
    if best.is_some() {
        return best
    }
    for s in result.specializations.specs.iter() {
        const o = &s.value.overlay
        for e in o.spans.iter() {
            const span = e.value
            if span.file_id != fid or !span_contains(span, offset) {
                continue
            }
            const ty = o.node_types.get(e.key)
            if ty.is_none() {
                continue
            }
            if best.is_none() or span.length < best_len {
                best = Some(TypedHit { node = e.key, span = span, ty = ty.unwrap() })
                best_len = span.length
            }
        }
    }
    return best
}

pub type TargetHit = struct {
    node: NodeId
    span: SourceSpan
    target: ResolvedTarget
}

// The innermost node at `offset` with a resolved target.
pub fn target_at(result: &TypeCheckResult, fid: i32, offset: usize) TargetHit? {
    let best: TargetHit? = null
    let best_len: usize = 0
    for e in result.spans.iter() {
        const span = e.value
        if span.file_id != fid or !span_contains(span, offset) {
            continue
        }
        const t = result.get_target(e.key)
        if t.is_none() {
            continue
        }
        if best.is_none() or span.length < best_len {
            best = Some(TargetHit { node = e.key, span = span, target = t.unwrap() })
            best_len = span.length
        }
    }
    if best.is_some() {
        return best
    }
    for s in result.specializations.specs.iter() {
        const o = &s.value.overlay
        for e in o.spans.iter() {
            const span = e.value
            if span.file_id != fid or !span_contains(span, offset) {
                continue
            }
            const t = o.resolved_targets.get(e.key)
            if t.is_none() {
                continue
            }
            if best.is_none() or span.length < best_len {
                best = Some(TargetHit { node = e.key, span = span, target = t.unwrap() })
                best_len = span.length
            }
        }
    }
    return best
}

// A node's checked type, from the base tables or the first overlay holding it.
pub fn type_of_node(result: &TypeCheckResult, node: NodeId) Ty? {
    const base = result.get_type(node)
    if base.is_some() {
        return base
    }
    for s in result.specializations.specs.iter() {
        const t = s.value.overlay.node_types.get(node)
        if t.is_some() {
            return t
        }
    }
    return null
}

// The largest typed node ending exactly at `end` - the receiver chain of a member access whose `.`
// follows at `end` (`allocator.vtable` for a cursor on `.alloc`). Largest, not smallest: the full
// chain is the receiver, an inner node is a fragment of it.
pub fn typed_ending_at(result: &TypeCheckResult, fid: i32, end: usize) TypedHit? {
    let best: TypedHit? = null
    let best_len: usize = 0
    for e in result.spans.iter() {
        const span = e.value
        if span.file_id != fid or span.start + span.length != end {
            continue
        }
        const ty = result.get_type(e.key)
        if ty.is_none() {
            continue
        }
        if best.is_none() or span.length > best_len {
            best = Some(TypedHit { node = e.key, span = span, ty = ty.unwrap() })
            best_len = span.length
        }
    }
    if best.is_some() {
        return best
    }
    for s in result.specializations.specs.iter() {
        const o = &s.value.overlay
        for e in o.spans.iter() {
            const span = e.value
            if span.file_id != fid or span.start + span.length != end {
                continue
            }
            const ty = o.node_types.get(e.key)
            if ty.is_none() {
                continue
            }
            if best.is_none() or span.length > best_len {
                best = Some(TypedHit { node = e.key, span = span, ty = ty.unwrap() })
                best_len = span.length
            }
        }
    }
    return best
}

pub type FieldHit = struct {
    decl_span: SourceSpan
    ty: Ty
}

// The named field of the nominal behind `recv` (references peeled), with its declared type. The
// checker records no target for field access, so member-position words resolve through this.
pub fn member_field(result: &TypeCheckResult, recv: Ty, name: String) FieldHit? {
    let t = recv
    loop {
        result.interner.node(t) match {
            NRef(inner) => { t = inner }
            NNominal(nn) => {
                const def = result.nominals.find(nn.id)
                if def.is_none() {
                    return null
                }
                return def.unwrap().* match {
                    NomStruct(sd) => field_by_name(&sd, name)
                    NomEnum(_) => null
                }
            }
            else => { return null }
        }
    }
    return null
}

// The field a cursor in member position names: `text[wstart..]` is the word, the receiver is
// whatever typed node ends at the dot before it (`?.` peeled). Null when the cursor is not in
// member position or the receiver has no such field - a UFCS method, say.
pub fn member_at(result: &TypeCheckResult, fid: i32, text: String, wstart: usize,
    wname: String) FieldHit? {
    if wstart == 0 or text[wstart - 1] != '.' {
        return null
    }
    const rend = if wstart >= 2 and text[wstart - 2] == '?' { wstart - 2 } else { wstart - 1 }
    const recv = typed_ending_at(result, fid, rend)
    if recv.is_none() {
        return null
    }
    return member_field(result, recv.unwrap().ty, wname)
}

fn field_by_name(sd: &StructDef, name: String) FieldHit? {
    for &f in sd.fields {
        if f.name == name {
            return Some(FieldHit { decl_span = f.decl_span, ty = f.ty })
        }
    }
    return null
}

// A node's recorded span, from the base tables or the first overlay holding it.
pub fn span_of_node(result: &TypeCheckResult, node: NodeId) SourceSpan? {
    const base = result.get_span(node)
    if base.is_some() {
        return base
    }
    for s in result.specializations.specs.iter() {
        const sp = s.value.overlay.spans.get(node)
        if sp.is_some() {
            return sp
        }
    }
    return null
}

// Where a resolved target's declaration lives. Null when the target cannot be mapped back to source
// (a synthesized declaration, a span the checker never recorded).
pub fn target_decl_span(result: &TypeCheckResult, target: &ResolvedTarget) SourceSpan? {
    return target.* match {
        RtFunction(id) => result.functions.find_by_id(id) match {
            Some(s) => real_span(s.decl_span)
            None => null
        }
        RtLocal(n) => span_of_node(result, n)
        RtStructField(nom, idx) => field_span(result, nom, idx)
        RtEnumVariant(nom, idx) => variant_span(result, nom, idx)
        RtSpecialized(sid) => result.specializations.specs.get_ref(sid) match {
            Some(sp) => real_span(sp.decl.span)
            None => null
        }
        RtConst(fqn) => const_decl_span(result, fqn)
    }
}

// Where the cursor's word points, given the target covering it. `Enum.Variant` records ONE variant
// target spanning the whole reference, so a cursor on the qualifier - the word the target starts
// at, with a `.` right after it - names the ENUM; everything else resolves as its target does.
pub fn cursor_decl_span(result: &TypeCheckResult, hit: &TargetHit, text: String, wstart: usize,
    wend: usize) SourceSpan? {
    const on_qualifier = hit.span.start == wstart and wend < text.len and text[wend] == '.'
    return hit.target match {
        RtEnumVariant(nom, _) => if on_qualifier { nominal_span(result, nom) }
        else { target_decl_span(result, &hit.target) }
        _ => target_decl_span(result, &hit.target)
    }
}

fn real_span(s: SourceSpan) SourceSpan? {
    if s.file_id < 0 {
        return null
    }
    return Some(s)
}

// The declaration span of a nominal by id - the qualifier half of `Enum.Variant` resolves here.
pub fn nominal_span(result: &TypeCheckResult, nom: NominalId) SourceSpan? {
    const def = result.nominals.find(nom)
    if def.is_none() {
        return null
    }
    return def.unwrap().* match {
        NomStruct(sd) => real_span(sd.decl_span)
        NomEnum(ed) => real_span(ed.decl_span)
    }
}

fn field_span(result: &TypeCheckResult, nom: NominalId, idx: u32) SourceSpan? {
    const def = result.nominals.find(nom)
    if def.is_none() {
        return null
    }
    return def.unwrap().* match {
        NomStruct(sd) => {
            if idx as usize >= sd.fields.len {
                return null
            }
            real_span(sd.fields[idx as usize].decl_span)
        }
        NomEnum(_) => null
    }
}

fn variant_span(result: &TypeCheckResult, nom: NominalId, idx: u32) SourceSpan? {
    const def = result.nominals.find(nom)
    if def.is_none() {
        return null
    }
    return def.unwrap().* match {
        NomEnum(ed) => {
            if idx as usize >= ed.variants.len {
                return null
            }
            real_span(ed.variants[idx as usize].decl_span)
        }
        NomStruct(_) => null
    }
}

// `RtConst` is recorded on every read AND on the ConstDecl node itself; the decl's node spans the
// whole `const N: T = init` declaration while reads span an identifier, so the widest entry is the
// declaration.
fn const_decl_span(result: &TypeCheckResult, fqn: String) SourceSpan? {
    let best: SourceSpan? = null
    for e in result.resolved_targets.iter() {
        const same = e.value match {
            RtConst(f) => f == fqn
            _ => false
        }
        if !same {
            continue
        }
        const span = result.get_span(e.key)
        if span.is_none() {
            continue
        }
        const s = span.unwrap()
        const wider = best match {
            Some(b) => s.length > b.length
            None => true
        }
        if wider {
            best = Some(s)
        }
    }
    return best
}

// The declaration span of the nominal behind `ty`, peeling references. Null for primitives,
// functions, tuples, vars - anything without a nominal declaration.
pub fn nominal_decl_span(result: &TypeCheckResult, ty: Ty) SourceSpan? {
    let t = ty
    loop {
        result.interner.node(t) match {
            NRef(inner) => { t = inner }
            NNominal(nn) => {
                const def = result.nominals.find(nn.id)
                if def.is_none() {
                    return null
                }
                return def.unwrap().* match {
                    NomStruct(sd) => real_span(sd.decl_span)
                    NomEnum(ed) => real_span(ed.decl_span)
                }
            }
            else => { return null }
        }
    }
    return null
}

// Render `ty` the way diagnostics do: short nominal names, `&`/array sugar. `vars` names a generic
// signature's free type variables (`checker.type_param_names`).
pub fn render_ty(result: &TypeCheckResult, ty: Ty, vars: &Dict(VarId, String)? = null,
    allocator: &Allocator? = null) OwnedString {
    let sb = string_builder(32, allocator)
    let reg: &NominalRegistry? = Some(&result.nominals)
    format_with_names(&result.interner, ty, &sb, reg, vars)
    const out = sb.to_string()
    sb.deinit()
    return out
}

// Whether `ty` renders without leaking inference internals: ground, or every free variable in it
// carries a declared `$T` name - the hover/hint gate inside generic bodies (closed types only,
// RFC-023 §3, with named signature vars counting as closed for display).
pub fn renderable_ty(result: &TypeCheckResult, ty: Ty, vars: &Dict(VarId, String)) bool {
    if result.interner.is_ground(ty) {
        return true
    }
    return result.interner.node(ty) match {
        NVar(v) => vars.get(v.id).is_some()
        NRef(inner) => renderable_ty(result, inner, vars)
        NArray(a) => renderable_ty(result, a.elem, vars)
        NNominal(nn) => children_renderable(result, nn.args, vars)
        NFunc(f) => children_renderable(result, f.params, vars) and renderable_ty(result, f.ret,
            vars)
        NTuple(span) => children_renderable(result, span, vars)
        NRecord(_) => false
        else => true
    }
}

fn children_renderable(result: &TypeCheckResult, span: ChildSpan, vars: &Dict(VarId, String)) bool {
    for i in 0..span.len {
        if !renderable_ty(result, result.interner.child_at(span, i), vars) {
            return false
        }
    }
    return true
}

pub fn same_target(a: &ResolvedTarget, b: &ResolvedTarget) bool {
    return a.* match {
        RtFunction(x) => b.* match { RtFunction(y) => x == y, _ => false }
        RtLocal(x) => b.* match { RtLocal(y) => x == y, _ => false }
        RtStructField(xn, xi) => b.* match {
            RtStructField(yn, yi) => xn == yn and xi == yi
            _ => false
        }
        RtEnumVariant(xn, xi) => b.* match {
            RtEnumVariant(yn, yi) => xn == yn and xi == yi
            _ => false
        }
        RtSpecialized(x) => b.* match { RtSpecialized(y) => x == y, _ => false }
        RtConst(x) => b.* match { RtConst(y) => x == y, _ => false }
    }
}

// Every use-site span resolving to `target`, project-wide. The declaration itself is not included
// (except the ConstDecl node, which carries its own RtConst entry); callers wanting it add
// `target_decl_span`.
pub fn reference_spans(result: &TypeCheckResult, target: &ResolvedTarget,
    allocator: &Allocator? = null) List(SourceSpan) {
    let out: List(SourceSpan) = list(8, allocator)
    for e in result.resolved_targets.iter() {
        const v = e.value
        if !same_target(&v, target) {
            continue
        }
        const span = result.get_span(e.key)
        if span.is_some() {
            push_unique(&out, span.unwrap())
        }
    }
    // Generic-body use sites live in the instantiation overlays; several instantiations share the
    // same source nodes, so spans dedupe.
    for s in result.specializations.specs.iter() {
        const o = &s.value.overlay
        for e in o.resolved_targets.iter() {
            const v = e.value
            if !same_target(&v, target) {
                continue
            }
            const span = o.spans.get(e.key)
            if span.is_some() {
                push_unique(&out, span.unwrap())
            }
        }
    }
    return out
}

fn push_unique(out: &List(SourceSpan), span: SourceSpan) {
    for &s in out {
        if s.file_id == span.file_id and s.start == span.start and s.length == span.length {
            return
        }
    }
    out.push(span)
}

// Byte-wise is UTF-8-correct here: FLang identifiers are ASCII-only (lexer.f
// `is_ident_continuation`), and multi-byte sequences never contain ASCII bytes, so a non-ASCII byte
// simply terminates the scan on a codepoint boundary.
pub fn is_ident_char(c: u8) bool {
    if c >= 'a' and c <= 'z' {
        return true
    }
    if c >= 'A' and c <= 'Z' {
        return true
    }
    if c >= '0' and c <= '9' {
        return true
    }
    return c == '_'
}

// The identifier under the cursor and where it starts, with a leading `#` kept when present
// (template names index as `#name`). Null when `offset` is not on an identifier.
pub type IdentAt = struct {
    start: usize
    name: String
}

pub fn identifier_at(text: String, offset: usize) IdentAt? {
    if offset >= text.len or !is_ident_char(text[offset]) {
        return null
    }
    let start = offset
    while start > 0 and is_ident_char(text[start - 1]) {
        start = start - 1
    }
    let end = offset
    while end < text.len and is_ident_char(text[end]) {
        end = end + 1
    }
    if start > 0 and text[start - 1] == '#' {
        start = start - 1
    }
    return Some(.{ start = start, name = text[start..end] })
}

// Whether `ty` is the void type.
pub fn is_void_ty(result: &TypeCheckResult, ty: Ty) bool {
    return result.interner.node(ty) match {
        NVoid => true
        _ => false
    }
}

// Tests

test "identifier_at expands to word boundaries and keeps a template hash" {
    const src = "let count = #gen(x)"
    assert_eq(identifier_at(src, 5).unwrap().name, "count", "middle of a word")
    assert_eq(identifier_at(src, 4).unwrap().name, "count", "first char")
    assert_eq(identifier_at(src, 4).unwrap().start, 4 as usize, "word start reported")
    assert_eq(identifier_at(src, 13).unwrap().name, "#gen", "template name keeps its hash")
    assert_eq(identifier_at(src, 13).unwrap().start, 12 as usize, "start covers the hash")
    assert_true(identifier_at(src, 3).is_none(), "whitespace is not an identifier")
    assert_true(identifier_at(src, 100).is_none(), "past the end")
}

test "same_target distinguishes variants and payloads" {
    const a = ResolvedTarget.RtFunction(3u32)
    const b = ResolvedTarget.RtFunction(3u32)
    const c = ResolvedTarget.RtFunction(4u32)
    const l = ResolvedTarget.RtLocal(3 as NodeId)
    assert_true(same_target(&a, &b), "equal function ids match")
    assert_true(!same_target(&a, &c), "different ids do not")
    assert_true(!same_target(&a, &l), "different variants do not")
}
