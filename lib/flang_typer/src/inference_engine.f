// Hindley-Milner unification, fresh-var allocation, level tracking, generalisation, specialisation
// - over interned type handles (RFC-024).
//
// The engine returns `UnifyOutcome` values - never diagnostics. Callers translate outcomes via
// `reporter.f` and attach their own context (span, error code, message template).
//
// State:
//   - `uf`               equivalence partitions over `VarId`
//   - `interner`         the type table: every type the engine stores or
//                        hands back is a handle into it, one node per
//                        distinct shape, the table the single owner
//   - `bindings`         each (rep) var -> its bound type handle
//   - `prim_constraints` narrowed vars: rep → allowed `PrimitiveKind` set
//   - `binding_undo` / `prim_undo` parallel undo stacks for speculative regions
//   - `level`            cursor for let-generalisation (`enter_level` / `exit_level`)
//   - `var_counter`      next `VarId` (engine-owned; not a global)
//   - `allocator`        backing for the table and scratch lists
//
// A speculative region (`push_checkpoint` … `rollback` / `commit`) snapshots
// every piece of mutable state so `try_unify` can abandon a unification completely. The undo stacks
// mirror the union-find's own stack frame- for-frame, so all three roll back together in one
// operation.

import std.allocator
import std.collections.dict
import std.collections.journal
import std.collections.list
import std.collections.set
import std.option
import std.string_builder
import std.test

import flang_core.span

import flang_typer.coercion
import flang_typer.copyable
import flang_typer.interner
import flang_typer.nominal_registry
import flang_typer.scheme
import flang_typer.type
import flang_typer.union_find
import flang_typer.well_known

// ─────────────────────────────────────────────────────────────────────
// UnifyOutcome - structured result, no diagnostics
// ─────────────────────────────────────────────────────────────────────

pub type UnifyOk = struct {
    ty: Ty
    cost: u32 // number of coercions applied; 0 for pure structural unification
}

// Two concrete types disagreed at a leaf. The engine returns the originating pair - not the
// sub-types of nested mismatches - so the reporter can present "expected `T`, got `U`" with the
// values the caller actually wrote. Nested unifications stop at the first leaf failure and
// propagate this same outcome upward.
pub type Mismatch = struct {
    actual: Ty
    expected: Ty
}

pub type OccursDetails = struct {
    var_id: VarId
    ty: Ty
}

// What kind of arity disagreed. Distinguished so the reporter can phrase the error in domain terms
// (function vs tuple vs nominal etc.).
pub type ArityKind = enum {
    FuncParams
    TupleLength
    NominalArgs
    ArrayLength
    RecordFields
}

pub type ArityDetails = struct {
    what: ArityKind
    expected: usize
    actual: usize
}

pub type PrimViolation = struct {
    got: Ty
    allowed: PrimSet
}

// Variant prefix `Uni` keeps these out of the global variant namespace where stdlib's `Result.Ok` /
// `Option.Some` already live. FLang resolves unqualified variants ahead of same-named types across
// every imported module, so a bare `Ok` here would silently win over `Result.Ok` at consumer sites
// and break completely unrelated stdlib code.
pub type UnifyOutcome = enum {
    Unified(UnifyOk)
    UniMismatch(Mismatch)
    UniOccursCheck(OccursDetails)
    UniArityMismatch(ArityDetails)
    UniPrimConstraint(PrimViolation)
}

pub fn is_ok(self: &UnifyOutcome) bool {
    return self.* match {
        Unified(_) => true
        _ => false
    }
}

// ─────────────────────────────────────────────────────────────────────
// Speculative-region undo entries
// ─────────────────────────────────────────────────────────────────────

// Records one mutation of `bindings`. `prev` is `Some(old)` when the entry overwrote an existing
// binding, `None` when it was a fresh insert (so rollback removes the entry instead of restoring a
// value).
type BindingUndo = struct {
    var_id: VarId
    prev: Ty?
}

type PrimConstraintUndo = struct {
    var_id: VarId
    prev: PrimSet? // null = the entry was new (rollback deletes)
}

// One mutation of `levels`. Mirrors `BindingUndo`: `prev` distinguishes overwrite (restore) from
// insert (delete on rollback).
type LevelUndo = struct {
    var_id: VarId
    prev: Level?
}

// ─────────────────────────────────────────────────────────────────────
// Engine
// ─────────────────────────────────────────────────────────────────────

pub type Engine = struct {
    uf: UnionFind(VarId)
    interner: TypeInterner
    bindings: Dict(VarId, Ty)
    prim_constraints: Dict(VarId, PrimSet)
    // Level per partition, keyed by representative `VarId`. The rep's level is the *minimum* of
    // every member's original level so that `generalize` doesn't accidentally quantify a var that
    // was unified with a shallower-scope var. Without this, `resolve_var` would return whatever
    // level the caller happened to pass in - soundness bug for let-polymorphism.
    levels: Dict(VarId, Level)

    binding_undo: Journal(BindingUndo)
    prim_undo: Journal(PrimConstraintUndo)
    level_undo: Journal(LevelUndo)

    var_counter: u32
    level: Level
    // Nominal-aware coercion rules need to resolve well-known FQNs (Option, String, Slice, Type).
    // The checker calls `set_nominal_registry` after `collect_nominals` finishes; until then
    // nominal-aware rules silently no-op.
    nominals: &NominalRegistry?
    allocator: &Allocator?
}

pub fn engine(allocator: &Allocator? = null) Engine {
    let uf: UnionFind(VarId) = union_find(allocator)
    let bindings: Dict(VarId, Ty) = dict(allocator)
    let prim_constraints: Dict(VarId, PrimSet) = dict(allocator)
    let levels: Dict(VarId, Level) = dict(allocator)
    let bu: Journal(BindingUndo) = journal(allocator)
    let pu: Journal(PrimConstraintUndo) = journal(allocator)
    let lu: Journal(LevelUndo) = journal(allocator)
    return .{
        uf = move uf,
        interner = type_interner(allocator),
        bindings = move bindings,
        prim_constraints = move prim_constraints,
        levels = move levels,
        binding_undo = move bu,
        prim_undo = move pu,
        level_undo = move lu,
        var_counter = 0u32,
        level = 0u32,
        nominals = null,
        allocator = allocator,
    }
}

// Wire the nominal registry into the engine. Coercion rules that resolve well-known FQNs (Option,
// String, Slice, Type) start firing after this is set; before, they silently no-op so plain
// HM-without-sugar works in isolation.
pub fn set_nominal_registry(self: &Engine, reg: &NominalRegistry) {
    self.nominals = Some(reg)
}

pub fn deinit(self: &Engine) {
    self.uf.deinit()
    self.interner.deinit()
    self.bindings.deinit()
    self.prim_constraints.deinit()
    self.levels.deinit()
    self.binding_undo.deinit()
    self.prim_undo.deinit()
    self.level_undo.deinit()
}

// Element form (README, Expected functions). The value carries its own allocator.
pub fn deinit(self: &Engine, allocator: &Allocator) {
    self.deinit()
}

// Hand the filled type table to the caller and leave a stand-in. The bindings still name handles of
// the moved table, so nothing may resolve through this engine afterwards - the next demand readies
// a fresh one.
pub fn take_interner(self: &Engine) TypeInterner {
    let out = move self.interner
    self.interner = type_interner(self.allocator, 0)
    return move out
}

// Replace the engine's table with one carried from an earlier demand, so the handles already minted
// into it (carried nominal bodies) stay valid and equal shapes intern to the ids they already hold.
// Only sound on an engine that has not interned anything of its own yet.
pub fn set_interner(self: &Engine, it: TypeInterner) {
    self.interner.deinit()
    self.interner = move it
}

// The shape behind a handle - engine-side shorthand.
pub fn ty_node(self: &Engine, t: Ty) TyNode {
    return self.interner.node(t)
}

pub fn is_var(self: &Engine, t: Ty) bool {
    return self.interner.is_var(t)
}

// ─────────────────────────────────────────────────────────────────────
// Level management - let-generalisation cursor
// ─────────────────────────────────────────────────────────────────────

pub fn enter_level(self: &Engine) {
    self.level = self.level + 1u32
}

pub fn exit_level(self: &Engine) {
    if self.level == 0u32 {
        panic("exit_level: level underflow")
    }
    self.level = self.level - 1u32
}

// ─────────────────────────────────────────────────────────────────────
// Fresh variables
// ─────────────────────────────────────────────────────────────────────

pub fn fresh_var(self: &Engine) Ty {
    let id = self.var_counter
    self.var_counter = id + 1u32
    set_level(self, id, self.level)
    return self.interner.var_of(TyVar { id = id, level = self.level })
}

// Advance the variable counter without interning a node. Replaying a skipped pass burns the
// variables the pass would have minted so later phases' id streams match a cold check's; the
// carried table already holds whatever nodes those variables named, so interning again would only
// grow it (the pass minted at its own level, the replay runs at the top one, and a var node is
// identified by id AND level).
pub fn burn_var(self: &Engine) {
    let id = self.var_counter
    self.var_counter = id + 1u32
    set_level(self, id, self.level)
}

// Allocate a fresh variable whose eventual binding must be one of the given primitive kinds. This
// is what keeps a numeric literal from binding to a nominal during overload resolution, where a
// candidate is accepted or rejected by whether unification succeeds.
pub fn fresh_constrained_var(self: &Engine, allowed: PrimSet) Ty {
    let t = self.fresh_var()
    let v = self.ty_node(t) match {
        NVar(tv) => tv
        _ => panic("fresh_var didn't return a var")
    }
    set_prim_constraint(self, v.id, allowed)
    return t
}

// ─────────────────────────────────────────────────────────────────────
// Compound constructors - thin veneers over the interner's builders. `mk_func` takes ownership of
// `params` (the list is scratch; the table keeps the shape) and frees it.
// ─────────────────────────────────────────────────────────────────────

pub fn mk_ref(self: &Engine, inner: Ty) Ty {
    return self.interner.ref_of(inner)
}

pub fn mk_array(self: &Engine, elem: Ty, length: usize) Ty {
    return self.interner.array_of(elem, length)
}

pub fn mk_func(self: &Engine, params: List(Ty), ret: Ty) Ty {
    const t = self.interner.func_of(&params, ret)
    params.deinit()
    return t
}

// ─────────────────────────────────────────────────────────────────────
// Resolution
//
// `resolve` walks the binding chain for a `Var`; deeper sub-types are untouched. `zonk` recursively
// resolves the entire shape, returning a handle with no remaining bound vars (unbound vars stay as
// `Var`).
// ─────────────────────────────────────────────────────────────────────

pub fn resolve(self: &Engine, t: Ty) Ty {
    return self.ty_node(t) match {
        NVar(v) => resolve_var(self, v)
        _ => t
    }
}

fn resolve_var(self: &Engine, v: TyVar) Ty {
    let rep = self.uf.find(v.id)
    let bound = self.bindings.get(rep)
    return bound match {
        Some(inner) => self.resolve(inner)
        None => {
            // Authoritative level lives on the rep, not the input var: after `unify_var_var` merges
            // partitions at different levels, only the rep's slot reflects the partition-wide min
            // level used by `generalize`.
            let lvl = self.levels.get(rep) match {
                Some(l) => l
                None => v.level
            }
            self.interner.var_of(.{ id = rep, level = lvl })
        }
    }
}

// Fully resolve `t`: every bound var inside is replaced by its binding, transitively. Ground shapes
// short-circuit - `zonk` is the identity on a type citing no vars, which is the common case.
pub fn zonk(self: &Engine, t: Ty) Ty {
    if self.interner.is_ground(t) {
        return t
    }
    let r = self.resolve(t)
    if self.interner.is_ground(r) {
        return r
    }
    return self.ty_node(r) match {
        NVar(_) => r
        NRef(inner) => self.interner.ref_of(self.zonk(inner))
        NArray(arr) => self.interner.array_of(self.zonk(arr.elem), arr.length)
        NFunc(f) => zonk_func(self, &f)
        NTuple(span) => zonk_tuple(self, span)
        NRecord(rec) => zonk_record(self, &rec)
        NNominal(nn) => zonk_nominal(self, &nn)
        _ => r
    }
}

fn zonk_span(self: &Engine, span: ChildSpan) List(Ty) {
    let out: List(Ty) = list(span.len, self.allocator)
    for i in 0..span.len {
        out.push(self.zonk(self.interner.child_at(span, i)))
    }
    return move out
}

fn zonk_func(self: &Engine, f: &NFuncNode) Ty {
    let ps = zonk_span(self, f.params)
    defer ps.deinit()
    return self.interner.func_of(&ps, self.zonk(f.ret))
}

fn zonk_tuple(self: &Engine, span: ChildSpan) Ty {
    let es = zonk_span(self, span)
    defer es.deinit()
    return self.interner.tuple_of(&es)
}

fn zonk_nominal(self: &Engine, nn: &NNominalNode) Ty {
    let as_ = zonk_span(self, nn.args)
    defer as_.deinit()
    return self.interner.nominal_of(nn.id, &as_)
}

fn zonk_record(self: &Engine, rec: &NRecordNode) Ty {
    let fs: List(Field) = list(rec.tys.len, self.allocator)
    defer fs.deinit()
    for i in 0..rec.tys.len {
        fs.push(Field {
            name = self.interner.rec_name(rec, i),
            ty = self.zonk(self.interner.rec_ty(rec, i)),
            decl_span = self.interner.rec_span(rec, i),
            owned = false,
        })
    }
    return self.interner.record_of(&fs)
}

// ─────────────────────────────────────────────────────────────────────
// Substitution - pure `Var(id)` replacement, used by `specialize` and generic instantiation. No
// engine resolution: collapsing bound chains stays the caller's business.
// ─────────────────────────────────────────────────────────────────────

pub fn substitute_shared(self: &Engine, ty: Ty, subst: &Dict(VarId, Ty)) Ty {
    return self.interner.substitute(ty, subst, self.allocator)
}

// ─────────────────────────────────────────────────────────────────────
// Copyability - the derived bit behind `owned` (RFC-028)
// ─────────────────────────────────────────────────────────────────────

// `flang_typer.copyable` over the zonked type: a bound variable anywhere inside is followed, an
// unbound one is a leaf. True without a registry: nominal-aware answers need one, and until
// `set_nominal_registry` every nominal reads as copyable.
pub fn is_copyable(self: &Engine, ty: Ty) bool {
    const reg = self.nominals match {
        Some(r) => r
        None => return true
    }
    return is_copyable_ty(&self.interner, reg, self.zonk(ty), self.allocator)
}

// One hop of the derivation that cleared a type's copyable bit: the aggregate, the field that
// cleared it, and whether that field says `owned` itself or inherited the bit from its own type.
pub type CopyBlame = struct {
    owner: Ty
    field: String
    // The field's own type, or null when the field is declared `owned` and its type is beside the
    // point.
    field_ty: Ty?
    // The hop is an enum variant payload rather than a struct field.
    variant: bool
}

// The hops that made `ty` non-copyable, outermost first; nothing appended when `ty` is copyable.
// Virality is unreadable without them: a type three hops from any `owned` still refuses to be
// copied, and the chain is the only thing that says why.
//
// The probe at each field is `is_copyable`, so the two answers cannot disagree.
pub fn copy_blame(self: &Engine, ty: Ty, out: &List(CopyBlame)) {
    const t = self.resolve(ty)
    self.ty_node(t) match {
        NArray(arr) => self.copy_blame(arr.elem, out)
        NTuple(span) => blame_span(self, span, out)
        NRecord(rec) => blame_span(self, rec.tys, out)
        NNominal(nn) => blame_nominal(self, t, &nn, out)
        _ => {}
    }
}

fn blame_span(self: &Engine, span: ChildSpan, out: &List(CopyBlame)) {
    for i in 0..span.len {
        const el = self.interner.child_at(span, i)
        if !self.is_copyable(el) {
            self.copy_blame(el, out)
            return
        }
    }
}

fn blame_nominal(self: &Engine, ty: Ty, nn: &NNominalNode, out: &List(CopyBlame)) {
    const reg = self.nominals match {
        Some(r) => r
        None => return
    }
    reg.get(nn.id).* match {
        NomStruct(sd) => blame_struct(self, ty, &sd, nn, out)
        NomEnum(ed) => blame_enum(self, ty, &ed, nn, out)
    }
}

fn blame_struct(self: &Engine, ty: Ty, sd: &StructDef, nn: &NNominalNode, out: &List(CopyBlame)) {
    let subst = param_subst(&self.interner, &sd.type_params, nn.args, self.allocator)
    defer subst.deinit()
    for i in 0..sd.fields.len {
        if sd.fields[i].owned {
            out.push(CopyBlame {
                owner = ty,
                field = sd.fields[i].name,
                field_ty = null,
                variant = false,
            })
            return
        }
    }
    for i in 0..sd.fields.len {
        const ft = self.substitute_shared(sd.fields[i].ty, &subst)
        if !self.is_copyable(ft) {
            out.push(CopyBlame {
                owner = ty,
                field = sd.fields[i].name,
                field_ty = Some(ft),
                variant = false,
            })
            self.copy_blame(ft, out)
            return
        }
    }
}

fn blame_enum(self: &Engine, ty: Ty, ed: &EnumDef, nn: &NNominalNode, out: &List(CopyBlame)) {
    let subst = param_subst(&self.interner, &ed.type_params, nn.args, self.allocator)
    defer subst.deinit()
    for vi in 0..ed.variants.len {
        for pi in 0..ed.variants[vi].payloads.len {
            const pt = self.substitute_shared(ed.variants[vi].payloads[pi], &subst)
            if !self.is_copyable(pt) {
                out.push(CopyBlame {
                    owner = ty,
                    field = ed.variants[vi].name,
                    field_ty = Some(pt),
                    variant = true,
                })
                self.copy_blame(pt, out)
                return
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Occurs check - does `v` appear anywhere inside `t`?
// ─────────────────────────────────────────────────────────────────────

pub fn occurs_in(self: &Engine, v: VarId, t: Ty) bool {
    let r = self.resolve(t)
    return self.ty_node(r) match {
        NVar(other) => self.uf.find(other.id) == self.uf.find(v)
        NRef(inner) => self.occurs_in(v, inner)
        NArray(arr) => self.occurs_in(v, arr.elem)
        NFunc(f) => occurs_in_func(self, v, &f)
        NTuple(span) => occurs_in_span(self, v, span)
        NRecord(rec) => occurs_in_span(self, v, rec.tys)
        NNominal(nn) => occurs_in_span(self, v, nn.args)
        _ => false
    }
}

fn occurs_in_func(self: &Engine, v: VarId, f: &NFuncNode) bool {
    if occurs_in_span(self, v, f.params) {
        return true
    }
    return self.occurs_in(v, f.ret)
}

fn occurs_in_span(self: &Engine, v: VarId, span: ChildSpan) bool {
    for i in 0..span.len {
        if self.occurs_in(v, self.interner.child_at(span, i)) {
            return true
        }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────
// Unification
// ─────────────────────────────────────────────────────────────────────

// Unify `actual` into `expected`. Returns `Ok(UnifyOk { ty, cost })` on success - `ty` is the
// unified type and `cost` counts applied coercions. Any failure short-circuits and returns a
// structured outcome without mutating engine state.
//
// `actual` flowing into `expected` is the direction the coercion
// ladder respects (integer widening, `T → Option(T)`, etc.).
// Structural unification is direction-insensitive.
pub fn unify(self: &Engine, actual: Ty, expected: Ty) UnifyOutcome {
    let a = self.resolve(actual)
    let b = self.resolve(expected)
    return unify_resolved(self, a, b)
}

fn unify_resolved(self: &Engine, a: Ty, b: Ty) UnifyOutcome {
    // Error is poison - absorbs anything silently.
    if a.is_error() or b.is_error() {
        return UnifyOutcome.Unified(.{ ty = TY_ERROR, cost = 0 })
    }
    // Never is bottom - unifies with everything, taking the other type.
    if a.is_never() {
        return UnifyOutcome.Unified(.{ ty = b, cost = 0 })
    }
    if b.is_never() {
        return UnifyOutcome.Unified(.{ ty = a, cost = 0 })
    }

    // Both vars - merge their partitions. The first arg's rep wins (matches the union-find
    // contract) so concrete types accumulated by earlier unifications stay reachable.
    return self.ty_node(a) match {
        NVar(va) => self.ty_node(b) match {
            NVar(vb) => unify_var_var(self, va, vb)
            _ => bind_var(self, va, b)
        }
        _ => self.ty_node(b) match {
            NVar(vb) => bind_var(self, vb, a)
            _ => unify_concrete(self, a, b)
        }
    }
}

// Both sides concrete (no Var, no Never, no Error). Try structural unification first; on mismatch,
// fall through to the directional coercion ladder. `actual = a` flows into `expected = b`.
fn unify_concrete(self: &Engine, a: Ty, b: Ty) UnifyOutcome {
    // One node per distinct type: identical handles ARE the same type.
    if a == b {
        return make_ok(a)
    }
    let structural = unify_structural(self, a, b)
    if structural.is_ok() {
        return structural
    }

    let coerced = try_coercion(self, a, b)
    return coerced match {
        Some(c) => apply_coercion(self, move c, structural)
        None => structural
    }
}

// Walk the hardcoded coercion ladder for `(from, to)`. First rule that fires wins; ordering matters
// when two rules could both apply. Returns `null` when nothing matches - the caller propagates the
// original structural failure.
//
// Order: pure prim rules first (integer widening, float widening), then nominal-aware rules in the
// order most callers expect
// (string→byte-slice first, then array decay and slice-to-ref, then
// the `Type(T)` lift).
fn try_coercion(self: &Engine, raw_from: Ty, raw_to: Ty) Coercion? {
    const it = &self.interner
    // Prim rules match on the (already top-resolved) raw shapes, so the common failed probe pays no
    // allocation.
    let r1 = try_integer_widening(it, raw_from, raw_to, self.allocator)
    if r1.is_some() {
        return move r1
    }
    let r2 = try_float_widening(it, raw_from, raw_to, self.allocator)
    if r2.is_some() {
        return move r2
    }
    let r8 = try_char_to_u8(it, raw_from, raw_to, self.allocator)
    if r8.is_some() {
        return move r8
    }
    self.nominals match {
        Some(reg) => {
            // Nominal-aware rules are engine-free and match structurally, so bound vars inside the
            // types must be collapsed first.
            let from = self.zonk(raw_from)
            let to = self.zonk(raw_to)
            let r4 = try_string_to_byte_slice(it, from, to, reg, self.allocator)
            if r4.is_some() {
                return move r4
            }
            let r10 = try_byte_slice_to_string(it, from, to, reg, self.allocator)
            if r10.is_some() {
                return move r10
            }
            let r5 = try_array_decay(it, from, to, reg, self.allocator)
            if r5.is_some() {
                return move r5
            }
            let r7 = try_nominal_to_type(it, from, to, reg, self.allocator)
            if r7.is_some() {
                return move r7
            }
            let r9 = try_type_to_typeinfo(it, from, to, reg, self.allocator)
            if r9.is_some() {
                return move r9
            }
        }
        None => {}
    }
    return null
}

// Commit a coercion atomically: open a checkpoint, run every side- unification through the main
// `unify` loop, commit on full success, roll back on any failure. The checkpoint guarantees a
// partially- applied coercion can never leak state - whether or not the caller has its own outer
// checkpoint open.
//
// On rollback the original `fallback` outcome is returned so the reporter surfaces the leaf
// mismatch the caller actually wrote, not some derived side-unification failure.
fn apply_coercion(self: &Engine, c: Coercion, fallback: UnifyOutcome) UnifyOutcome {
    self.push_checkpoint()
    for &con in c.side_unifications {
        let out = self.unify(con.a, con.b)
        if !out.is_ok() {
            self.rollback()
            return fallback
        }
    }
    self.commit()
    return UnifyOutcome.Unified(UnifyOk { ty = c.result_ty, cost = c.cost })
}

fn unify_var_var(self: &Engine, va: TyVar, vb: TyVar) UnifyOutcome {
    let ra = self.uf.find(va.id)
    let rb = self.uf.find(vb.id)
    if ra == rb {
        return UnifyOutcome.Unified(.{ ty = self.interner.var_of(va), cost = 0 })
    }

    // Intersect prim constraints, if any. An empty intersection means the two narrow sets are
    // disjoint and the partitions can't merge.
    let merged_constraint = intersect_prim_constraints(self, ra, rb)
    if merged_constraint.is_some() and merged_constraint.unwrap().is_empty() {
        return poisoned(self, ra, UnifyOutcome.UniPrimConstraint(.{
            got = self.interner.var_of(va),
            allowed = 0u32,
        }))
    }

    // Compute the merged level *before* the merge - both reps still have their own slots at this
    // point. Use the min so the partition stays generalisable only from the outer-most binding
    // scope.
    let level_a = self.levels.get(ra) match { Some(l) => l, None => self.level }
    let level_b = self.levels.get(rb) match { Some(l) => l, None => self.level }
    let merged_level = if level_a < level_b { level_a } else { level_b }

    self.uf.merge(ra, rb)
    let new_rep = self.uf.find(ra)
    // Apply the merged constraint to the new rep; clear the loser.
    let loser = if new_rep == ra { rb } else { ra }
    clear_prim_constraint(self, loser)
    merged_constraint match {
        Some(allowed) => set_prim_constraint(self, new_rep, allowed)
        None => {}
    }
    // Stamp the merged level onto the rep and drop the loser's slot.
    set_level(self, new_rep, merged_level)
    clear_level(self, loser)
    return UnifyOutcome.Unified(.{ ty = self.interner.var_of(va), cost = 0 })
}

fn bind_var(self: &Engine, v: TyVar, concrete: Ty) UnifyOutcome {
    let rep = self.uf.find(v.id)

    if self.occurs_in(rep, concrete) {
        return UnifyOutcome.UniOccursCheck(.{ var_id = rep, ty = concrete })
    }

    // Honour prim constraint, if any.
    self.prim_constraints.get(rep) match {
        Some(allowed) => {
            let violation = check_prim_constraint(self, allowed, concrete)
            if violation.is_some() {
                return poisoned(self, rep, violation.unwrap())
            }
            clear_prim_constraint(self, rep)
        }
        None => {}
    }

    record_binding_undo(self, rep)
    self.bindings.set(rep, concrete)
    return UnifyOutcome.Unified(.{ ty = concrete, cost = 0 })
}

// Bind `rep` to the poison type and hand back the outcome that rejected it. A var whose constraint
// was violated has no type it could still take, and leaving it unbound makes every later reader of
// it report as well - the literal sweep's "cannot determine concrete type" on top of the error that
// already said why. `Error` absorbs into anything, so the one diagnostic stands alone. Recorded for
// undo like any binding, so a speculative overload trial rolls it back with everything else.
fn poisoned(self: &Engine, rep: VarId, outcome: UnifyOutcome) UnifyOutcome {
    record_binding_undo(self, rep)
    self.bindings.set(rep, TY_ERROR)
    return outcome
}

// `Some(PrimConstraint(...))` if `concrete` violates `allowed`, `None` otherwise.
fn check_prim_constraint(self: &Engine, allowed: PrimSet, concrete: Ty) UnifyOutcome? {
    let satisfied = self.ty_node(concrete) match {
        NPrim(p) => allowed.contains(p)
        _ => false
    }
    if satisfied {
        return null
    }
    return Some(UnifyOutcome.UniPrimConstraint(PrimViolation {
        got = concrete,
        allowed = allowed,
    }))
}

fn make_mismatch(a: Ty, b: Ty) UnifyOutcome {
    return UnifyOutcome.UniMismatch(Mismatch { actual = a, expected = b })
}

fn make_ok(ty: Ty) UnifyOutcome {
    return UnifyOutcome.Unified(UnifyOk { ty = ty, cost = 0u32 })
}

fn unify_structural(self: &Engine, a: Ty, b: Ty) UnifyOutcome {
    return self.ty_node(a) match {
        NPrim(pa) => unify_a_prim(self, pa, a, b)
        NRef(ia) => unify_a_ref(self, ia, a, b)
        NArray(aa) => unify_a_array(self, &aa, a, b)
        NFunc(fa) => unify_a_func(self, &fa, a, b)
        NTuple(ta) => unify_a_tuple(self, ta, a, b)
        NRecord(ra) => unify_a_record(self, &ra, a, b)
        NNominal(na) => unify_a_nominal(self, &na, a, b)
        NVoid => unify_a_void(self, a, b)
        _ => make_mismatch(a, b)
    }
}

fn unify_a_prim(self: &Engine, pa: PrimitiveKind, a: Ty, b: Ty) UnifyOutcome {
    return self.ty_node(b) match {
        NPrim(pb) => if pa == pb { make_ok(a) } else { make_mismatch(a, b) }
        _ => make_mismatch(a, b)
    }
}

fn unify_a_ref(self: &Engine, ia: Ty, a: Ty, b: Ty) UnifyOutcome {
    return self.ty_node(b) match {
        NRef(ib) => {
            let r = self.unify(ia, ib)
            if r.is_ok() {
                return make_ok(a)
            }
            r
        }
        _ => make_mismatch(a, b)
    }
}

fn unify_a_array(self: &Engine, aa: &NArrayNode, a: Ty, b: Ty) UnifyOutcome {
    return self.ty_node(b) match {
        NArray(ab) => unify_arrays(self, aa, &ab, a)
        _ => make_mismatch(a, b)
    }
}

fn unify_arrays(self: &Engine, aa: &NArrayNode, ab: &NArrayNode, a: Ty) UnifyOutcome {
    if aa.length != ab.length {
        return UnifyOutcome.UniArityMismatch(.{
            what = ArityKind.ArrayLength,
            expected = ab.length,
            actual = aa.length,
        })
    }
    let r = self.unify(aa.elem, ab.elem)
    if r.is_ok() {
        return make_ok(a)
    }
    return r
}

fn unify_a_func(self: &Engine, fa: &NFuncNode, a: Ty, b: Ty) UnifyOutcome {
    return self.ty_node(b) match {
        NFunc(fb) => unify_func(self, fa, &fb, a, b)
        _ => make_mismatch(a, b)
    }
}

fn unify_a_tuple(self: &Engine, ta: ChildSpan, a: Ty, b: Ty) UnifyOutcome {
    return self.ty_node(b) match {
        NTuple(tb) => unify_spans(self, ta, tb, a, ArityKind.TupleLength)
        NVoid => if ta.len == 0 { make_ok(b) } else { make_mismatch(a, b) }
        _ => make_mismatch(a, b)
    }
}

fn unify_a_record(self: &Engine, ra: &NRecordNode, a: Ty, b: Ty) UnifyOutcome {
    return self.ty_node(b) match {
        NRecord(rb) => unify_record(self, ra, &rb, a, b)
        _ => make_mismatch(a, b)
    }
}

fn unify_a_nominal(self: &Engine, na: &NNominalNode, a: Ty, b: Ty) UnifyOutcome {
    return self.ty_node(b) match {
        NNominal(nb) => unify_nominal(self, na, &nb, a, b)
        _ => make_mismatch(a, b)
    }
}

fn unify_a_void(self: &Engine, a: Ty, b: Ty) UnifyOutcome {
    return self.ty_node(b) match {
        NVoid => make_ok(a)
        NTuple(tb) => if tb.len == 0 { make_ok(a) } else { make_mismatch(a, b) }
        _ => make_mismatch(a, b)
    }
}

// Function types match EXACTLY: no coercion inside a parameter or the return. `fn(i32) i32` is not
// a `fn(i64) i64` - the callee would read its argument at the wrong width, and widening is not
// sound under contravariance anyway (reference parity, E2011 at the use site). Variables still
// bind, so `fn($T) $T` unifies with a concrete signature.
fn unify_func(self: &Engine, fa: &NFuncNode, fb: &NFuncNode, a: Ty, b: Ty) UnifyOutcome {
    if fa.params.len != fb.params.len {
        return UnifyOutcome.UniArityMismatch(.{
            what = ArityKind.FuncParams,
            expected = fb.params.len,
            actual = fa.params.len,
        })
    }
    for i in 0..fa.params.len {
        let pa = self.interner.child_at(fa.params, i)
        let pb = self.interner.child_at(fb.params, i)
        let r = unify_exact(self, pa, pb)
        if !r.is_ok() {
            return r
        }
    }
    let rr = unify_exact(self, fa.ret, fb.ret)
    if rr.is_ok() {
        return make_ok(a)
    }
    return rr
}

// Unify without the coercion ladder: vars bind as usual, two concrete types must be structurally
// identical.
fn unify_exact(self: &Engine, actual: Ty, expected: Ty) UnifyOutcome {
    let a = self.resolve(actual)
    let b = self.resolve(expected)
    if a.is_error() or b.is_error() {
        return UnifyOutcome.Unified(.{ ty = TY_ERROR, cost = 0 })
    }
    if a.is_never() {
        return UnifyOutcome.Unified(.{ ty = b, cost = 0 })
    }
    if b.is_never() {
        return UnifyOutcome.Unified(.{ ty = a, cost = 0 })
    }
    return self.ty_node(a) match {
        NVar(va) => self.ty_node(b) match {
            NVar(vb) => unify_var_var(self, va, vb)
            _ => bind_var(self, va, b)
        }
        _ => self.ty_node(b) match {
            NVar(vb) => bind_var(self, vb, a)
            _ => unify_structural(self, a, b)
        }
    }
}

fn unify_spans(self: &Engine, ta: ChildSpan, tb: ChildSpan, a: Ty, what: ArityKind) UnifyOutcome {
    if ta.len != tb.len {
        return UnifyOutcome.UniArityMismatch(.{
            what = what,
            expected = tb.len,
            actual = ta.len,
        })
    }
    for i in 0..ta.len {
        let ea = self.interner.child_at(ta, i)
        let eb = self.interner.child_at(tb, i)
        let r = self.unify(ea, eb)
        if !r.is_ok() {
            return r
        }
    }
    return make_ok(a)
}

fn unify_record(self: &Engine, ra: &NRecordNode, rb: &NRecordNode, a: Ty, b: Ty) UnifyOutcome {
    if ra.tys.len != rb.tys.len {
        return UnifyOutcome.UniArityMismatch(.{
            what = ArityKind.RecordFields,
            expected = rb.tys.len,
            actual = ra.tys.len,
        })
    }
    for i in 0..ra.tys.len {
        if self.interner.rec_name(ra, i) != self.interner.rec_name(rb, i) {
            return make_mismatch(a, b)
        }
        let r = self.unify(self.interner.rec_ty(ra, i), self.interner.rec_ty(rb, i))
        if !r.is_ok() {
            return r
        }
    }
    return make_ok(a)
}

fn unify_nominal(self: &Engine, na: &NNominalNode, nb: &NNominalNode, a: Ty, b: Ty) UnifyOutcome {
    if na.id != nb.id {
        return make_mismatch(a, b)
    }
    return unify_spans(self, na.args, nb.args, a, ArityKind.NominalArgs)
}

// ─────────────────────────────────────────────────────────────────────
// try_unify - speculative, always rolled back
// ─────────────────────────────────────────────────────────────────────

// Run `unify` inside a fresh checkpoint and discard every mutation regardless of outcome. Used by
// overload resolution and coercion-rule scoring to probe a candidate without committing. The
// returned `UnifyOutcome` is informational only - vars are not actually bound.
pub fn try_unify(self: &Engine, a: Ty, b: Ty) UnifyOutcome {
    self.push_checkpoint()
    let outcome = self.unify(a, b)
    self.rollback()
    return outcome
}

// ─────────────────────────────────────────────────────────────────────
// Speculative regions
// ─────────────────────────────────────────────────────────────────────

// Opens a speculative region over every mutable table: the union-find, the bindings, the primitive
// constraints and the levels. Regions nest; each `commit` or `rollback` closes the innermost. A
// checkpoint allocates nothing once the journals have reached their high-water mark.
pub fn push_checkpoint(self: &Engine) {
    self.uf.push_checkpoint()
    self.binding_undo.checkpoint()
    self.prim_undo.checkpoint()
    self.level_undo.checkpoint()
}

// Closes the innermost region and keeps its mutations. An enclosing region's `rollback` still
// undoes them. Panics when no region is open.
pub fn commit(self: &Engine) {
    self.uf.commit()
    self.binding_undo.commit()
    self.prim_undo.commit()
    self.level_undo.commit()
}

// Closes the innermost region and undoes its mutations, newest first: an overwritten entry gets its
// old value back, an inserted one is removed. Panics when no region is open.
pub fn rollback(self: &Engine) {
    self.uf.rollback()
    self.binding_undo.rollback(fn(entry: BindingUndo) {
        if entry.prev.is_some() {
            self.bindings.set(entry.var_id, entry.prev.unwrap())
        } else {
            let _discard = self.bindings.remove(entry.var_id)
        }
    })
    self.prim_undo.rollback(fn(entry: PrimConstraintUndo) {
        if entry.prev.is_some() {
            self.prim_constraints.set(entry.var_id, entry.prev.unwrap())
        } else {
            let _discard = self.prim_constraints.remove(entry.var_id)
        }
    })
    self.level_undo.rollback(fn(entry: LevelUndo) {
        if entry.prev.is_some() {
            self.levels.set(entry.var_id, entry.prev.unwrap())
        } else {
            let _discard = self.levels.remove(entry.var_id)
        }
    })
}

// ─────────────────────────────────────────────────────────────────────
// Scheme operations - generalise and specialise
// ─────────────────────────────────────────────────────────────────────

// Quantify every free variable of `t` whose level is deeper than the engine's current cursor. `t`
// is zonked first so any chain of bound vars is collapsed before the free-var walk.
pub fn generalize(self: &Engine, t: Ty) Scheme {
    let z = self.zonk(t)
    let quantified: Set(VarId) = set(self.allocator)
    free_vars(&self.interner, z, self.level, &quantified)
    if quantified.len() == 0 {
        quantified.deinit()
        return .{ quantified = null, body = z }
    }
    return .{ quantified = Some(self.interner.own_quantifiers(move quantified)), body = z }
}

// Instantiate `s` with engine-fresh variables substituted for every quantified id. The fresh vars
// carry the engine's current level - they're eligible for further unification but won't be
// re-quantified by `generalize` at the same level.
pub fn specialize(self: &Engine, s: &Scheme) Ty {
    if s.quantified.is_none() {
        return s.body
    }
    let subst: Dict(VarId, Ty) = dict(self.allocator)
    let t = self.specialize_capture(s, &subst)
    subst.deinit()
    return t
}

// `specialize`, but records the quantified-id → fresh-var mapping into
// `out` (untouched for a monomorphic scheme). The specialization pass zonks those fresh vars once
// inference settles to learn the concrete type each signature parameter was instantiated at (M10).
pub fn specialize_capture(self: &Engine, s: &Scheme, out: &Dict(VarId, Ty)) Ty {
    const q = s.quantified match {
        Some(q) => q
        None => return s.body
    }
    for old_id in q.* {
        let fresh = self.fresh_var()
        out.set(old_id, fresh)
    }
    return self.substitute_shared(s.body, out)
}

// ─────────────────────────────────────────────────────────────────────
// Internal - prim-constraint bookkeeping
// ─────────────────────────────────────────────────────────────────────

fn set_prim_constraint(self: &Engine, var_id: VarId, allowed: PrimSet) {
    record_prim_undo(self, var_id)
    self.prim_constraints.set(var_id, allowed)
}

fn clear_prim_constraint(self: &Engine, var_id: VarId) {
    if !self.prim_constraints.contains(var_id) {
        return
    }
    record_prim_undo(self, var_id)
    let _removed = self.prim_constraints.remove(var_id)
}

// Intersect the prim-constraint sets attached to two rep vars. `None` when neither var is
// constrained (the merge places no further restriction on the partition); otherwise the
// intersection, which may be empty - that signals an incompatible merge.
fn intersect_prim_constraints(self: &Engine, ra: VarId, rb: VarId) PrimSet? {
    let ca = self.prim_constraints.get(ra)
    let cb = self.prim_constraints.get(rb)
    if ca.is_none() and cb.is_none() {
        return null
    }
    if ca.is_none() {
        return cb
    }
    if cb.is_none() {
        return ca
    }
    return Some(ca.unwrap() & cb.unwrap())
}

// Logs the current binding of `var_id`, if a region is open, so a rollback can restore it. Called
// before every write to `bindings`.
fn record_binding_undo(self: &Engine, var_id: VarId) {
    if !self.binding_undo.is_open() {
        return
    }
    self.binding_undo.record(BindingUndo { var_id = var_id, prev = self.bindings.get(var_id) })
}

fn record_prim_undo(self: &Engine, var_id: VarId) {
    if !self.prim_undo.is_open() {
        return
    }
    self.prim_undo.record(PrimConstraintUndo {
        var_id = var_id,
        prev = self.prim_constraints.get(var_id),
    })
}

fn set_level(self: &Engine, var_id: VarId, lvl: Level) {
    record_level_undo(self, var_id)
    self.levels.set(var_id, lvl)
}

fn clear_level(self: &Engine, var_id: VarId) {
    if !self.levels.contains(var_id) {
        return
    }
    record_level_undo(self, var_id)
    self.levels.remove(var_id)
}

fn record_level_undo(self: &Engine, var_id: VarId) {
    if !self.level_undo.is_open() {
        return
    }
    self.level_undo.record(LevelUndo { var_id = var_id, prev = self.levels.get(var_id) })
}

// ─────────────────────────────────────────────────────────────────────
// Tests - unification, the coercion ladder, generalisation
// ─────────────────────────────────────────────────────────────────────

test "fresh vars are unique and bind to concrete types" {
    let eng = engine()
    defer eng.deinit()
    let fv1 = eng.fresh_var()
    let fv2 = eng.fresh_var()
    assert_true(fv1 != fv2, "fresh vars have distinct nodes")

    let out = eng.unify(fv1, ty_i32())
    assert_true(out.is_ok(), "var unifies with i32")
    assert_eq(eng.resolve(fv1), ty_i32(), "var resolves to i32 after bind")
}

test "integer widening succeeds, narrowing fails" {
    let eng = engine()
    defer eng.deinit()
    let widen = eng.unify(ty_i8(), ty_i32())
    assert_true(widen.is_ok(), "i8 widens to i32")
    let cost = widen match { Unified(uo) => uo.cost, _ => 0u32 }
    assert_eq(cost, 1u32, "widening costs one coercion")

    assert_true(!eng.unify(ty_i64(), ty_i32()).is_ok(), "i64 does not narrow to i32")
}

test "float widening is one-directional" {
    let eng = engine()
    defer eng.deinit()
    assert_true(eng.unify(ty_f32(), ty_f64()).is_ok(), "f32 widens to f64")
    assert_true(!eng.unify(ty_f64(), ty_f32()).is_ok(), "f64 does not narrow to f32")
}

test "cross-signedness widens only to a strictly larger signed rank" {
    let eng = engine()
    defer eng.deinit()
    assert_true(eng.unify(ty_u8(), ty_i32()).is_ok(), "u8 widens to i32")
    assert_true(!eng.unify(ty_u32(), ty_i32()).is_ok(), "u32 does not widen to i32 at equal rank")
}

test "occurs check rejects infinite types" {
    let eng = engine()
    defer eng.deinit()
    let fv = eng.fresh_var()
    let wrapping = eng.mk_ref(fv)
    let outcome = eng.unify(fv, wrapping)
    let is_occurs = outcome match { UniOccursCheck(_) => true, _ => false }
    assert_true(is_occurs, "unifying v with &v is an occurs-check failure")
}

test "tuple arity mismatch is reported" {
    let eng = engine()
    defer eng.deinit()
    let t2: List(Ty) = list(2)
    t2.push(ty_i32())
    t2.push(ty_bool())
    defer t2.deinit()
    let t3: List(Ty) = list(3)
    t3.push(ty_i32())
    t3.push(ty_bool())
    t3.push(ty_i64())
    defer t3.deinit()
    // Through a reference: builder mutations two field-hops deep on a LOCAL value struct do not
    // stick (docs/known-issues.md).
    let it = &eng.interner
    let outcome = eng.unify(it.tuple_of(&t2), it.tuple_of(&t3))
    let is_arity = outcome match { UniArityMismatch(_) => true, _ => false }
    assert_true(is_arity, "2-tuple vs 3-tuple is an arity mismatch")
}

test "try_unify rolls back on success" {
    let eng = engine()
    defer eng.deinit()
    let fv = eng.fresh_var()
    assert_true(eng.try_unify(fv, ty_i32()).is_ok(), "speculative unify succeeds")
    assert_true(eng.is_var(eng.resolve(fv)), "var stays unbound after try_unify")
}

test "generalize then specialize yields a fresh quantified var" {
    let eng = engine()
    defer eng.deinit()
    eng.enter_level()
    let inner = eng.fresh_var()
    eng.exit_level()
    let scheme = eng.generalize(inner)
    assert_true(scheme.quantified_len() == 1, "one quantified var")
    let inst = eng.specialize(&scheme)
    assert_true(eng.is_var(inst), "the instantiation is a var")
    assert_true(inst != inner, "specialised var is fresh")
}

test "zonk is the identity on ground types and collapses bound vars" {
    let eng = engine()
    defer eng.deinit()
    let fv = eng.fresh_var()
    let r = eng.mk_ref(fv)
    assert_true(!eng.interner.is_ground(r), "&?v is not ground")
    let _o = eng.unify(fv, ty_i32())
    const z = eng.zonk(r)
    assert_eq(z, eng.mk_ref(ty_i32()), "zonk collapses the bound var to one canonical node")
    assert_eq(eng.zonk(z), z, "zonk of a ground shape is the identity")
}

// ─────────────────────────────────────────────────────────────────────
// Tests - copyability (RFC-028)
// ─────────────────────────────────────────────────────────────────────

fn cp_struct(params: List(VarId), fields: List(Field)) StructDef {
    return StructDef {
        fqn = "",
        module = "m",
        is_pub = true,
        type_params = move params,
        fields = move fields,
        decl_span = none_span(),
        deprecation = null,
        is_simd = false,
        is_foreign = false,
    }
}

fn cp_field(name: String, ty: Ty, owned: bool) Field {
    return Field { name = name, ty = ty, decl_span = none_span(), owned = owned }
}

fn cp_nominal(eng: &Engine, id: NominalId, args: List(Ty)) Ty {
    const t = eng.interner.nominal_of(id, &args)
    args.deinit()
    return t
}

// `type Handle = struct { owned fd: i32 }` - the leaf resource every case below is built from.
fn cp_handle(reg: &NominalRegistry) NominalId {
    let fs: List(Field) = list(1)
    fs.push(cp_field("fd", prim_of(PrimitiveKind.I32), true))
    return reg.register(NominalDef.NomStruct(cp_struct(list(0), move fs)), $"m.Handle")
}

test "an owned field clears the bit, and nothing else does" {
    let reg = nominal_registry()
    defer reg.deinit()
    let eng = engine()
    defer eng.deinit()
    eng.set_nominal_registry(&reg)

    let plain: List(Field) = list(1)
    plain.push(cp_field("fd", prim_of(PrimitiveKind.I32), false))
    const p = reg.register(NominalDef.NomStruct(cp_struct(list(0), move plain)), $"m.Plain")
    const h = cp_handle(&reg)

    assert_true(eng.is_copyable(cp_nominal(&eng, p, list(0))),
        "the same shape without `owned` stays copyable")
    assert_true(!eng.is_copyable(cp_nominal(&eng, h, list(0))),
        "a field declared `owned` makes the type non-copyable")
}

test "the bit is transitive through by-value fields, and stops at a reference" {
    let reg = nominal_registry()
    defer reg.deinit()
    let eng = engine()
    defer eng.deinit()
    eng.set_nominal_registry(&reg)

    const h = cp_handle(&reg)
    const handle = cp_nominal(&eng, h, list(0))

    // `struct { h: Handle }` holds the resource; `struct { h: &Handle }` only views it.
    let by_value: List(Field) = list(1)
    by_value.push(cp_field("h", handle, false))
    const owner = reg.register(NominalDef.NomStruct(cp_struct(list(0), move by_value)), $"m.Owner")

    let by_ref: List(Field) = list(1)
    by_ref.push(cp_field("h", eng.mk_ref(handle), false))
    const viewer = reg.register(NominalDef.NomStruct(cp_struct(list(0), move by_ref)), $"m.Viewer")

    assert_true(!eng.is_copyable(cp_nominal(&eng, owner, list(0))),
        "a non-copyable field type is inherited")
    assert_true(eng.is_copyable(cp_nominal(&eng, viewer, list(0))),
        "a reference is a leaf: it shares the value rather than holding it")
    assert_true(eng.is_copyable(eng.mk_ref(handle)), "`&Handle` is itself copyable")
    assert_true(!eng.is_copyable(eng.mk_array(handle, 2)), "an array of them is not")
}

test "the bit follows the instantiation, not the declaration" {
    let reg = nominal_registry()
    defer reg.deinit()
    let eng = engine()
    defer eng.deinit()
    eng.set_nominal_registry(&reg)

    const h = cp_handle(&reg)
    const handle = cp_nominal(&eng, h, list(0))

    // `type Box($T) = struct { v: T }` - the field type is the parameter, so the answer can only
    // come from substituting the instantiation's argument in.
    const tv: VarId = 1u32
    let params: List(VarId) = list(1)
    params.push(tv)
    let fs: List(Field) = list(1)
    fs.push(cp_field("v", eng.interner.var_of(TyVar { id = tv, level = 0u32 }), false))
    const box = reg.register(NominalDef.NomStruct(cp_struct(move params, move fs)), $"m.Box")

    let with_handle: List(Ty) = list(1)
    with_handle.push(handle)
    let with_int: List(Ty) = list(1)
    with_int.push(prim_of(PrimitiveKind.I32))

    assert_true(!eng.is_copyable(cp_nominal(&eng, box, move with_handle)),
        "Box(Handle) is not copyable")
    assert_true(eng.is_copyable(cp_nominal(&eng, box, move with_int)), "Box(i32) is")
}

test "a view over a non-copyable element stays copyable" {
    let reg = nominal_registry()
    defer reg.deinit()
    let eng = engine()
    defer eng.deinit()
    eng.set_nominal_registry(&reg)

    const h = cp_handle(&reg)
    const handle = cp_nominal(&eng, h, list(0))

    // `Slice` and `String` are this shape. They need no rule of their own - the walk reaches a
    // reference and stops, which is the same reason a slice is a view.
    const tv: VarId = 2u32
    let params: List(VarId) = list(1)
    params.push(tv)
    let fs: List(Field) = list(2)
    fs.push(cp_field("ptr", eng.mk_ref(eng.interner.var_of(TyVar { id = tv, level = 0u32 })),
            false))
    fs.push(cp_field("len", prim_of(PrimitiveKind.USize), false))
    const view = reg.register(NominalDef.NomStruct(cp_struct(move params, move fs)), $"m.View")

    let args: List(Ty) = list(1)
    args.push(handle)
    assert_true(eng.is_copyable(cp_nominal(&eng, view, move args)),
        "View(Handle) views, so it copies")
}

test "an enum variant payload propagates the bit" {
    let reg = nominal_registry()
    defer reg.deinit()
    let eng = engine()
    defer eng.deinit()
    eng.set_nominal_registry(&reg)

    const h = cp_handle(&reg)
    const handle = cp_nominal(&eng, h, list(0))

    let payload: List(Ty) = list(1)
    payload.push(handle)
    let variants: List(VariantDef) = list(2)
    variants.push(VariantDef { name = "None", payloads = list(0), decl_span = none_span() })
    variants.push(VariantDef { name = "Some", payloads = move payload, decl_span = none_span() })
    const maybe = reg.register(NominalDef.NomEnum(EnumDef {
        fqn = "",
        module = "m",
        is_pub = true,
        type_params = list(0),
        variants = move variants,
        tag_values = null,
        decl_span = none_span(),
        deprecation = null,
    }), $"m.Maybe")

    assert_true(!eng.is_copyable(cp_nominal(&eng, maybe, list(0))),
        "a payload carries the bit even though it cannot declare `owned`")
}
