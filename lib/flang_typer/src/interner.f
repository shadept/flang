// TypeInterner - the type table (RFC-024). One `TyNode` per distinct type; a `Ty` is an index into
// it. Identity is the node's shape: two structurally equal types (`decl_span` metadata ignored)
// intern to the same id, so `a == b` on handles is type equality. `Void`, `Never`, `Error` and the
// 14 primitives hold the fixed ids `type.f` declares, so the common leaves never hash.
//
// The identity a lookup hashes is `TyKey`, a fixed-size struct with derived `hash`/`op_eq`, so
// `Dict` settles collisions itself. Interning allocates nothing on a hit.
//
// A node's children are `Ty` handles sliced out of one flat `children` array. The table owns two
// lists' worth of storage; nothing else owns any part of a type.
//
// The empty tuple and `Void` keep distinct ids: unification treats them as the same type by
// convention, but consumers match them as different shapes.
//
// A `Record`'s key includes its field names, which are `String` views into module sources - the
// table must not outlive the sources of the types it interned. `Var` nodes key on (id, level):
// `generalize`'s free-variable walk reads the level off the node, so a var whose partition level
// moved interns as a fresh node rather than surfacing a stale level.
//
// Rendering is `format`, which walks the node graph and appends the diagnostic text (vars print as
// `?id`, dropping the level their identity carries).

import std.allocator
import std.derive
import std.dict
import std.list
import std.option
import std.string
import std.string_builder
import std.test
import flang_core.span
import flang_typer.type

// One child window into `TypeInterner.children`.
pub type ChildSpan = struct {
    start: usize
    len: usize
}

pub type NArrayNode = struct {
    elem: Ty
    length: usize
}

pub type NFuncNode = struct {
    params: ChildSpan
    ret: Ty
}

// `tys` windows `children`; `names_start` windows `rec_names` / `rec_spans`, with the same length
// as `tys`.
pub type NRecordNode = struct {
    tys: ChildSpan
    names_start: usize
}

pub type NNominalNode = struct {
    id: NominalId
    args: ChildSpan
}

// The shape behind a handle. Variant names carry the `N` prefix to stay out of the global variant
// namespace.
pub type TyNode = enum {
    NVar(TyVar)
    NPrim(PrimitiveKind)
    NRef(Ty)
    NArray(NArrayNode)
    NFunc(NFuncNode)
    NTuple(ChildSpan)
    NRecord(NRecordNode)
    NNominal(NNominalNode)
    NNever
    NVoid
    NError
}

// Structural identity of one node, as a fixed-size value `Dict` can hash and compare itself.
//
// Variable-arity children do not fit in a fixed struct, so a child sequence is interned separately
// (see `KidsKey`) and enters the key as the single id `kids`. `a`/`b` are the two scalar slots the
// variants use differently - no variant needs more than two values beside its children:
//
//   TAG_VAR      a = var id            b = level
//   TAG_REF      a = elem
//   TAG_ARRAY    a = elem              b = length
//   TAG_FUNC     a = return type                     kids = params
//   TAG_TUPLE                                        kids = elements
//   TAG_RECORD                                       kids = (name, type) fields
//   TAG_NOMINAL  a = NominalId                       kids = type arguments
//
// The seeded leaves (void, never, error, the prims) hold fixed ids and are reached through
// `prim_of` and the `TY_*` constants, so they are never looked up by shape and need no key.
pub type TyKey = struct {
    tag: u32
    a: u32
    b: usize
    kids: u32
}

#derive(TyKey, eq, hash)

// One cell of an interned child sequence, built right to left and terminated by `KIDS_NIL`. Equal
// sequences reach the same id because each cell is a fixed struct the dict compares exactly;
// sequences sharing a suffix share its cells.
//
// Record fields need a name in the cell and everything else does not, so they get their own cell
// type and their own dict rather than making every cell carry an unused 16-byte `String`. Ids come
// from one counter, and a key's tag says which dict its `kids` came from.
pub type KidsKey = struct {
    head: Ty
    tail: u32
}

#derive(KidsKey, eq, hash)

pub type FieldKidsKey = struct {
    head: Ty
    name: String
    tail: u32
}

#derive(FieldKidsKey, eq, hash)

const KIDS_NIL: u32 = 0

const TAG_VAR: u32 = 1
const TAG_REF: u32 = 2
const TAG_ARRAY: u32 = 3
const TAG_FUNC: u32 = 4
const TAG_TUPLE: u32 = 5
const TAG_RECORD: u32 = 6
const TAG_NOMINAL: u32 = 7

pub type TypeInterner = struct {
    nodes: List(TyNode)
    children: List(Ty)
    // Whether the node's whole subtree is variable-free. `zonk` is the identity on ground types,
    // which is the common case by far.
    ground: List(bool)
    // Record field names and declaration spans, windowed by `NRecordNode`.
    rec_names: List(String)
    rec_spans: List(SourceSpan)
    // Structural key -> id.
    by_key: Dict(TyKey, Ty)
    // Interned child sequences: cons cell -> list id. Ids live in their own space, never mixing
    // with `Ty`, so nothing outside this file can mistake one for a type.
    kids: Dict(KidsKey, u32)
    field_kids: Dict(FieldKidsKey, u32)
    kids_next: u32
    // ponytail: measurement scaffolding for the RFC-024 key rework; drop once the numbers land.
    n_calls: usize
    n_hits: usize
    allocator: &Allocator?
}

// Default capacity of the per-node arrays, from measured checks: a stdlib-bound check of a trivial
// project interns ~26k nodes (every check seeds the whole stdlib, so that is the floor), the
// 106-module compiler ~205k. Covering the floor skips the first nine doublings of four parallel
// arrays; a big check grows a few times from here.
const SEED_CAPACITY: usize = 32768

// The fixed leaves `type_interner` seeds: void, never, <error>, 14 prims.
const SEED_LEN: usize = 17

pub fn type_interner(allocator: &Allocator? = null) TypeInterner {
    return type_interner(allocator, SEED_CAPACITY)
}

// `capacity` sizes the per-node arrays. The one-argument form uses a default that fits a real
// check; pass 0 for a table that only stands in for one (an empty result, an engine that has handed
// its table away).
pub fn type_interner(allocator: &Allocator?, capacity: usize) TypeInterner {
    let self = TypeInterner {
        nodes = list(capacity, allocator),
        children = list(capacity, allocator),
        ground = list(capacity, allocator),
        rec_names = list(0, allocator),
        rec_spans = list(0, allocator),
        by_key = dict(capacity, allocator),
        kids = dict(capacity, allocator),
        field_kids = dict(0, allocator),
        kids_next = 1,
        n_calls = 0,
        n_hits = 0,
        allocator = allocator,
    }
    seed_leaf(&self, TyNode.NVoid)
    seed_leaf(&self, TyNode.NNever)
    seed_leaf(&self, TyNode.NError)
    // `prim_of` (type.f) fixes the id order; this is that order.
    const prims: [PrimitiveKind; 14] = [PrimitiveKind.Bool, PrimitiveKind.I8, PrimitiveKind.I16,
        PrimitiveKind.I32, PrimitiveKind.I64, PrimitiveKind.ISize, PrimitiveKind.U8,
        PrimitiveKind.U16, PrimitiveKind.U32, PrimitiveKind.U64, PrimitiveKind.USize,
        PrimitiveKind.F32, PrimitiveKind.F64, PrimitiveKind.Char]
    for p in prims {
        seed_leaf(&self, TyNode.NPrim(p))
    }
    return self
}

fn probe(self: &TypeInterner, key: TyKey) Ty? {
    self.n_calls = self.n_calls + 1
    const hit = self.by_key.get(key)
    if hit.is_some() {
        self.n_hits = self.n_hits + 1
    }
    return hit
}

fn seed_leaf(self: &TypeInterner, node: TyNode) {
    self.nodes.push(node)
    self.ground.push(true)
}

// Id of the cell `(head, tail)`, minting one if this is its first appearance.
fn cons(self: &TypeInterner, head: Ty, tail: u32) u32 {
    const cell = KidsKey { head = head, tail = tail }
    const hit = self.kids.get(cell)
    if hit.is_some() {
        return hit.unwrap()
    }
    const id = self.kids_next
    self.kids_next = self.kids_next + 1
    self.kids.set(cell, id)
    return id
}

fn cons_field(self: &TypeInterner, head: Ty, name: String, tail: u32) u32 {
    const cell = FieldKidsKey { head = head, name = name, tail = tail }
    const hit = self.field_kids.get(cell)
    if hit.is_some() {
        return hit.unwrap()
    }
    const id = self.kids_next
    self.kids_next = self.kids_next + 1
    self.field_kids.set(cell, id)
    return id
}

// Id of `ids` as a sequence. Built right to left so a shared suffix reuses its cells.
fn intern_kids(self: &TypeInterner, ids: &List(Ty)) u32 {
    let tail = KIDS_NIL
    let i = ids.len
    while i > 0 {
        i = i - 1
        tail = self.cons(ids[i], tail)
    }
    return tail
}

// The record analogue: a field's name is part of its identity.
fn intern_field_kids(self: &TypeInterner, fields: &List(Field)) u32 {
    let tail = KIDS_NIL
    let i = fields.len
    while i > 0 {
        i = i - 1
        tail = self.cons_field(fields[i].ty, fields[i].name, tail)
    }
    return tail
}

pub fn deinit(self: &TypeInterner) {
    self.nodes.deinit()
    self.children.deinit()
    self.ground.deinit()
    self.rec_names.deinit()
    self.rec_spans.deinit()
    self.by_key.deinit()
    self.kids.deinit()
    self.field_kids.deinit()
}

pub fn len(self: &TypeInterner) usize {
    return self.nodes.len
}

// Whether the table holds nothing beyond the seeded leaves - a stand-in no check has interned into,
// carrying no type worth adopting.
pub fn is_pristine(self: &TypeInterner) bool {
    return self.nodes.len == SEED_LEN
}

// ponytail: measurement scaffolding; drop with n_calls/n_hits.
pub fn stats_report(self: &TypeInterner) OwnedString {
    return $"interner: {self.nodes.len} types, {self.n_calls} calls, {self.n_hits} hits, {self.n_calls - self.n_hits} misses, {self.kids.len()} cons cells\n  nodes={self.nodes.capacity_bytes()} children={self.children.capacity_bytes()} ground={self.ground.capacity_bytes()} rec_names={self.rec_names.capacity_bytes()} rec_spans={self.rec_spans.capacity_bytes()} by_key={self.by_key.capacity_bytes()} kids={self.kids.capacity_bytes()} field_kids={self.field_kids.capacity_bytes()} total={self.capacity_bytes()}"
}

// Backing arrays only, like every `capacity_bytes`.
pub fn capacity_bytes(self: &TypeInterner) usize {
    return self.nodes.capacity_bytes() + self.children.capacity_bytes()
        + self.ground.capacity_bytes() + self.rec_names.capacity_bytes()
        + self.rec_spans.capacity_bytes() + self.by_key.capacity_bytes()
        + self.kids.capacity_bytes() + self.field_kids.capacity_bytes()
}

pub fn node(self: &TypeInterner, id: Ty) TyNode {
    return self.nodes[id]
}

// Whether `id`'s whole subtree is variable-free.
pub fn is_ground(self: &TypeInterner, id: Ty) bool {
    return self.ground[id]
}

pub fn is_var(self: &TypeInterner, id: Ty) bool {
    return self.nodes[id] match { NVar(_) => true, _ => false }
}

// The window's handles as a slice of the flat child array. The slice aliases the array's current
// buffer: interning anything may grow the array and move it, so never hold one across an interning
// call - loop with `child_at` instead.
pub fn child_ids(self: &TypeInterner, span: ChildSpan) Ty[] {
    return self.children[span.start..span.start + span.len]
}

// One handle out of a window, read through the array's current buffer - safe to interleave with
// interning.
pub fn child_at(self: &TypeInterner, span: ChildSpan, i: usize) Ty {
    return self.children[span.start + i]
}

// Record field accessors, windowed by the node's `names_start` / `tys`.
pub fn rec_name(self: &TypeInterner, n: &NRecordNode, i: usize) String {
    return self.rec_names[n.names_start + i]
}

pub fn rec_span(self: &TypeInterner, n: &NRecordNode, i: usize) SourceSpan {
    return self.rec_spans[n.names_start + i]
}

pub fn rec_ty(self: &TypeInterner, n: &NRecordNode, i: usize) Ty {
    return self.children[n.tys.start + i]
}

pub fn var_of(self: &TypeInterner, v: TyVar) Ty {
    const key = TyKey { tag = TAG_VAR, a = v.id, b = v.level as usize, kids = KIDS_NIL }
    const hit = self.probe(key)
    if hit.is_some() {
        return hit.unwrap()
    }
    return add(self, key, TyNode.NVar(v), false)
}

pub fn ref_of(self: &TypeInterner, elem: Ty) Ty {
    const key = TyKey { tag = TAG_REF, a = elem, b = 0, kids = KIDS_NIL }
    const hit = self.probe(key)
    if hit.is_some() {
        return hit.unwrap()
    }
    return add(self, key, TyNode.NRef(elem), self.is_ground(elem))
}

pub fn array_of(self: &TypeInterner, elem: Ty, length: usize) Ty {
    const key = TyKey { tag = TAG_ARRAY, a = elem, b = length, kids = KIDS_NIL }
    const hit = self.probe(key)
    if hit.is_some() {
        return hit.unwrap()
    }
    const node = TyNode.NArray(.{ elem = elem, length = length })
    return add(self, key, node, self.is_ground(elem))
}

pub fn func_of(self: &TypeInterner, params: &List(Ty), ret: Ty) Ty {
    const key = TyKey { tag = TAG_FUNC, a = ret, b = 0, kids = self.intern_kids(params) }
    const hit = self.probe(key)
    if hit.is_some() {
        return hit.unwrap()
    }

    const g = all_ground(self, params) and self.is_ground(ret)
    const span = push_children(self, params)
    const node = TyNode.NFunc(.{ params = span, ret = ret })
    return add(self, key, node, g)
}

pub fn tuple_of(self: &TypeInterner, elems: &List(Ty)) Ty {
    const key = TyKey { tag = TAG_TUPLE, a = 0, b = 0, kids = self.intern_kids(elems) }
    const hit = self.probe(key)
    if hit.is_some() {
        return hit.unwrap()
    }

    const g = all_ground(self, elems)
    const span = push_children(self, elems)
    return add(self, key, TyNode.NTuple(span), g)
}

// The fields carry the names, the declaration spans AND the field types (`Field.ty` is a handle).
// The first interning of a shape decides the spans the table stores - they are metadata, outside
// the identity.
pub fn record_of(self: &TypeInterner, fields: &List(Field)) Ty {
    const key = TyKey { tag = TAG_RECORD, a = 0, b = 0, kids = self.intern_field_kids(fields) }
    const hit = self.probe(key)
    if hit.is_some() {
        return hit.unwrap()
    }

    let g = true
    const start = self.children.len
    const names_start = self.rec_names.len
    for i in 0..fields.len {
        self.children.push(fields[i].ty)
        self.rec_names.push(fields[i].name)
        self.rec_spans.push(fields[i].decl_span)
        if !self.is_ground(fields[i].ty) {
            g = false
        }
    }
    const span = ChildSpan { start = start, len = fields.len }
    const node = TyNode.NRecord(.{ tys = span, names_start = names_start })
    return add(self, key, node, g)
}

pub fn nominal_of(self: &TypeInterner, id: NominalId, args: &List(Ty)) Ty {
    const key = TyKey { tag = TAG_NOMINAL, a = id, b = 0, kids = self.intern_kids(args) }
    const hit = self.probe(key)
    if hit.is_some() {
        return hit.unwrap()
    }

    const g = all_ground(self, args)
    const span = push_children(self, args)
    const node = TyNode.NNominal(.{ id = id, args = span })
    return add(self, key, node, g)
}

fn all_ground(self: &TypeInterner, ids: &List(Ty)) bool {
    for id in ids {
        if !self.is_ground(id) {
            return false
        }
    }
    return true
}

fn push_children(self: &TypeInterner, ids: &List(Ty)) ChildSpan {
    const start = self.children.len
    for id in ids { self.children.push(id) }
    return .{ start = start, len = ids.len }
}

fn add(self: &TypeInterner, key: TyKey, node: TyNode, g: bool) Ty {
    const id = self.nodes.len as Ty
    self.nodes.push(node)
    self.ground.push(g)
    self.by_key.set(key, id)
    return id
}

// ─────────────────────────────────────────────────────────────────────
// Rendering for diagnostics - the tree representation's `format`, off the node graph. Vars print as
// `?id`; the level that is part of their identity is not shown.
// ─────────────────────────────────────────────────────────────────────

pub fn format(self: &TypeInterner, id: Ty, sb: &StringBuilder) {
    self.node(id) match {
        NVar(v) => {
            sb.append("?")
            sb.append(v.id)
        }
        NPrim(p) => sb.append(prim_name(p))
        NRef(inner) => {
            sb.append("&")
            self.format(inner, sb)
        }
        NArray(arr) => {
            sb.append("[")
            self.format(arr.elem, sb)
            sb.append("; ")
            sb.append(arr.length)
            sb.append("]")
        }
        NFunc(f) => {
            sb.append("fn(")
            const ps = self.child_ids(f.params)
            for i in 0..ps.len {
                if i > 0 {
                    sb.append(", ")
                }
                self.format(ps[i], sb)
            }
            sb.append(") ")
            self.format(f.ret, sb)
        }
        NTuple(span) => {
            sb.append("(")
            const es = self.child_ids(span)
            for i in 0..es.len {
                if i > 0 {
                    sb.append(", ")
                }
                self.format(es[i], sb)
            }
            if es.len == 1 {
                sb.append(",")
            }
            sb.append(")")
        }
        NRecord(rec) => {
            sb.append("{ ")
            for i in 0..rec.tys.len {
                if i > 0 {
                    sb.append(", ")
                }
                sb.append(self.rec_name(&rec, i))
                sb.append(": ")
                self.format(self.rec_ty(&rec, i), sb)
            }
            sb.append(" }")
        }
        NNominal(nn) => {
            sb.append("#")
            sb.append(nn.id)
            const as_ = self.child_ids(nn.args)
            if as_.len > 0 {
                sb.append("(")
                for i in 0..as_.len {
                    if i > 0 {
                        sb.append(", ")
                    }
                    self.format(as_[i], sb)
                }
                sb.append(")")
            }
        }
        NNever => sb.append("never")
        NVoid => sb.append("void")
        NError => sb.append("<error>")
    }
}

// Test helper: `format` into a fresh buffer.
fn render(it: &TypeInterner, id: Ty) OwnedString {
    let sb = string_builder(16)
    it.format(id, &sb)
    return sb.to_string()
}

test "equal shapes intern to one id, distinct shapes to two" {
    let it = type_interner()
    defer it.deinit()
    const before = it.len()

    let ea: List(Ty) = list(2)
    ea.push(prim_of(PrimitiveKind.I32))
    ea.push(prim_of(PrimitiveKind.Bool))
    defer ea.deinit()
    let eb: List(Ty) = list(2)
    eb.push(prim_of(PrimitiveKind.I32))
    eb.push(prim_of(PrimitiveKind.Bool))
    defer eb.deinit()

    const ia = it.tuple_of(&ea)
    const ib = it.tuple_of(&eb)
    assert_eq(ia, ib, "one shape, one id")
    assert_eq(it.len(), before + 1, "the duplicate added no node")

    let ec: List(Ty) = list(1)
    ec.push(prim_of(PrimitiveKind.I32))
    defer ec.deinit()
    assert_true(it.tuple_of(&ec) != ia, "a different shape gets its own id")
}

test "leaves hold their fixed ids without touching the table" {
    let it = type_interner()
    defer it.deinit()
    assert_eq(it.len(), 17 as usize, "three leaves plus fourteen prims")
    const p = prim_of(PrimitiveKind.I32)
    const shape_ok = it.node(p) match {
        NPrim(k) => k == PrimitiveKind.I32
        _ => false
    }
    assert_true(shape_ok, "the fixed prim id names its kind")
    const v = render(&it, TY_VOID)
    defer v.deinit()
    assert_true(v.as_view() == "void", "void renders at id 0")
    const e = render(&it, TY_ERROR)
    defer e.deinit()
    assert_true(e.as_view() == "<error>", "error renders at id 2")
}

test "a var keys on id and level together" {
    let it = type_interner()
    defer it.deinit()
    const a = it.var_of(TyVar { id = 4u32, level = 1u32 })
    const b = it.var_of(TyVar { id = 4u32, level = 1u32 })
    assert_eq(a, b, "same id and level, same node")
    // `free_vars` reads the level off the node, so a moved level must surface as a fresh node
    // rather than a stale cached one.
    assert_true(it.var_of(TyVar { id = 4u32, level = 9u32 }) != a, "a moved level is a fresh node")
    assert_true(it.var_of(TyVar { id = 5u32, level = 1u32 }) != a,
        "a different var is a different node")
}

test "empty tuple and void stay distinct shapes" {
    let it = type_interner()
    defer it.deinit()
    let none: List(Ty) = list(0)
    defer none.deinit()
    assert_true(it.tuple_of(&none) != TY_VOID, "the unit convention does not fuse the ids")
}

test "groundness marks var-citing subtrees" {
    let it = type_interner()
    defer it.deinit()
    const v = it.var_of(TyVar { id = 1u32, level = 0u32 })
    assert_true(!it.is_ground(v), "a var is not ground")
    const rv = it.ref_of(v)
    assert_true(!it.is_ground(rv), "a shape citing a var is not ground")
    const ri = it.ref_of(prim_of(PrimitiveKind.I32))
    assert_true(it.is_ground(ri), "a var-free shape is ground")
}

test "format renders through the node graph" {
    let it = type_interner()
    defer it.deinit()
    let ps: List(Ty) = list(1)
    ps.push(it.ref_of(prim_of(PrimitiveKind.U8)))
    defer ps.deinit()
    const f = it.func_of(&ps, TY_VOID)
    let sb = string_builder(16)
    defer sb.deinit()
    it.format(f, &sb)
    assert_true(sb.as_view() == "fn(&u8) void", "the rendering matches the tree representation's")
}

test "a duplicate allocates nothing lasting; teardown returns the storage" {
    let c = counting_allocator(global())
    let a = c.allocator()
    let it = type_interner(Some(&a))

    let fields: List(Field) = list(1)
    fields.push(Field {
        name = "x",
        ty = it.ref_of(prim_of(PrimitiveKind.I64)),
        decl_span = none_span(),
    })
    defer fields.deinit()

    const first = it.record_of(&fields)
    const after_first = c.live_bytes
    assert_true(after_first > 0, "the table is on the heap")
    for _i in 0usize..100usize {
        assert_eq(it.record_of(&fields), first, "same shape, same id")
    }
    assert_eq(c.live_bytes, after_first, "100 duplicates added no lasting byte")

    it.deinit()
    assert_true(c.live_bytes < after_first, "teardown returned the table's storage")
}
