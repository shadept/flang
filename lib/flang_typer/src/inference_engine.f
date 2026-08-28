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
import std.dict
import std.list
import std.option
import std.set
import std.stack
import flang_typer.type
import flang_typer.interner
import flang_typer.scheme
import flang_typer.union_find
import flang_typer.coercion
import flang_typer.nominal_registry
import flang_typer.well_known
import std.test

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

    binding_undo: Stack(List(BindingUndo))
    prim_undo: Stack(List(PrimConstraintUndo))
    level_undo: Stack(List(LevelUndo))

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
    let bu: Stack(List(BindingUndo)) = stack(0, allocator)
    let pu: Stack(List(PrimConstraintUndo)) = stack(0, allocator)
    let lu: Stack(List(LevelUndo)) = stack(0, allocator)
    return .{
        uf = uf,
        interner = type_interner(allocator),
        bindings = bindings,
        prim_constraints = prim_constraints,
        levels = levels,
        binding_undo = bu,
        prim_undo = pu,
        level_undo = lu,
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
    // Drain undo stacks - each frame is its own list with its own buffer.
    loop {
        self.binding_undo.pop() match {
            Some(frame) => {
                let f = frame
                f.deinit()
            }
            None => break
        }
    }
    self.binding_undo.deinit()
    loop {
        self.prim_undo.pop() match {
            Some(frame) => {
                let f = frame
                f.deinit()
            }
            None => break
        }
    }
    self.prim_undo.deinit()
    loop {
        self.level_undo.pop() match {
            Some(frame) => {
                let f = frame
                f.deinit()
            }
            None => break
        }
    }
    self.level_undo.deinit()
}

// Hand the filled type table to the caller and leave a stand-in. The bindings still name handles of
// the moved table, so nothing may resolve through this engine afterwards - the next demand readies
// a fresh one.
pub fn take_interner(self: &Engine) TypeInterner {
    let out = self.interner
    self.interner = type_interner(self.allocator, 0)
    return out
}

// Replace the engine's table with one carried from an earlier demand, so the handles already minted
// into it (carried nominal bodies) stay valid and equal shapes intern to the ids they already hold.
// Only sound on an engine that has not interned anything of its own yet.
pub fn set_interner(self: &Engine, it: TypeInterner) {
    self.interner.deinit()
    self.interner = it
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
    return out
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
        })
    }
    return self.interner.record_of(&fs)
}

// ─────────────────────────────────────────────────────────────────────
// Substitution - pure `Var(id)` replacement, used by `specialize` and generic instantiation. No
// engine resolution: collapsing bound chains stays the caller's business.
// ─────────────────────────────────────────────────────────────────────

pub fn substitute_shared(self: &Engine, ty: Ty, subst: &Dict(VarId, Ty)) Ty {
    return self.ty_node(ty) match {
        NVar(v) => subst.get(v.id) match {
            Some(rep) => rep
            None => ty
        }
        NRef(inner) => self.interner.ref_of(self.substitute_shared(inner, subst))
        NArray(arr) => self.interner.array_of(self.substitute_shared(arr.elem, subst), arr.length)
        NFunc(f) => substitute_func(self, &f, subst)
        NTuple(span) => substitute_tuple(self, span, subst)
        NRecord(rec) => substitute_record(self, &rec, subst)
        NNominal(nn) => substitute_nominal(self, &nn, subst)
        _ => ty
    }
}

fn substitute_span(self: &Engine, span: ChildSpan, subst: &Dict(VarId, Ty)) List(Ty) {
    let out: List(Ty) = list(span.len, self.allocator)
    for i in 0..span.len {
        out.push(self.substitute_shared(self.interner.child_at(span, i), subst))
    }
    return out
}

fn substitute_func(self: &Engine, f: &NFuncNode, subst: &Dict(VarId, Ty)) Ty {
    let ps = substitute_span(self, f.params, subst)
    defer ps.deinit()
    return self.interner.func_of(&ps, self.substitute_shared(f.ret, subst))
}

fn substitute_tuple(self: &Engine, span: ChildSpan, subst: &Dict(VarId, Ty)) Ty {
    let es = substitute_span(self, span, subst)
    defer es.deinit()
    return self.interner.tuple_of(&es)
}

fn substitute_record(self: &Engine, rec: &NRecordNode, subst: &Dict(VarId, Ty)) Ty {
    let fs: List(Field) = list(rec.tys.len, self.allocator)
    defer fs.deinit()
    for i in 0..rec.tys.len {
        fs.push(Field {
            name = self.interner.rec_name(rec, i),
            ty = self.substitute_shared(self.interner.rec_ty(rec, i), subst),
            decl_span = self.interner.rec_span(rec, i),
        })
    }
    return self.interner.record_of(&fs)
}

fn substitute_nominal(self: &Engine, nn: &NNominalNode, subst: &Dict(VarId, Ty)) Ty {
    let as_ = substitute_span(self, nn.args, subst)
    defer as_.deinit()
    return self.interner.nominal_of(nn.id, &as_)
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
        Some(c) => apply_coercion(self, c, structural)
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
        return r1
    }
    let r2 = try_float_widening(it, raw_from, raw_to, self.allocator)
    if r2.is_some() {
        return r2
    }
    let r8 = try_char_to_u8(it, raw_from, raw_to, self.allocator)
    if r8.is_some() {
        return r8
    }
    self.nominals match {
        Some(reg) => {
            // Nominal-aware rules are engine-free and match structurally, so bound vars inside the
            // types must be collapsed first.
            let from = self.zonk(raw_from)
            let to = self.zonk(raw_to)
            let r4 = try_string_to_byte_slice(it, from, to, reg, self.allocator)
            if r4.is_some() {
                return r4
            }
            let r10 = try_byte_slice_to_string(it, from, to, reg, self.allocator)
            if r10.is_some() {
                return r10
            }
            let r5 = try_array_decay(it, from, to, reg, self.allocator)
            if r5.is_some() {
                return r5
            }
            let r6 = try_slice_to_reference(it, from, to, reg, self.allocator)
            if r6.is_some() {
                return r6
            }
            let r7 = try_nominal_to_type(it, from, to, reg, self.allocator)
            if r7.is_some() {
                return r7
            }
            let r9 = try_type_to_typeinfo(it, from, to, reg, self.allocator)
            if r9.is_some() {
                return r9
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

pub fn push_checkpoint(self: &Engine) {
    self.uf.push_checkpoint()
    let bu_frame: List(BindingUndo) = list(0, self.allocator)
    let pu_frame: List(PrimConstraintUndo) = list(0, self.allocator)
    let lu_frame: List(LevelUndo) = list(0, self.allocator)
    self.binding_undo.push(bu_frame)
    self.prim_undo.push(pu_frame)
    self.level_undo.push(lu_frame)
}

pub fn commit(self: &Engine) {
    self.uf.commit()
    let b = self.binding_undo.pop().expect("commit: no binding checkpoint")
    b.deinit()
    let p = self.prim_undo.pop().expect("commit: no prim checkpoint")
    p.deinit()
    let l = self.level_undo.pop().expect("commit: no level checkpoint")
    l.deinit()
}

pub fn rollback(self: &Engine) {
    self.uf.rollback()
    let b = self.binding_undo.pop().expect("rollback: no binding checkpoint")
    let i = b.len
    loop {
        if i == 0 {
            break
        }
        i = i - 1
        let entry = &b[i]
        if entry.prev.is_some() {
            self.bindings.set(entry.var_id, entry.prev.unwrap())
        } else {
            let _discard = self.bindings.remove(entry.var_id)
        }
    }
    b.deinit()

    let p = self.prim_undo.pop().expect("rollback: no prim checkpoint")
    let j = p.len
    loop {
        if j == 0 {
            break
        }
        j = j - 1
        let entry = &p[j]
        if entry.prev.is_some() {
            self.prim_constraints.set(entry.var_id, entry.prev.unwrap())
        } else {
            let _discard = self.prim_constraints.remove(entry.var_id)
        }
    }
    p.deinit()

    let l = self.level_undo.pop().expect("rollback: no level checkpoint")
    let k = l.len
    loop {
        if k == 0 {
            break
        }
        k = k - 1
        let entry = &l[k]
        if entry.prev.is_some() {
            self.levels.set(entry.var_id, entry.prev.unwrap())
        } else {
            let _discard = self.levels.remove(entry.var_id)
        }
    }
    l.deinit()
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
    return .{ quantified = quantified, body = z }
}

// Instantiate `s` with engine-fresh variables substituted for every quantified id. The fresh vars
// carry the engine's current level - they're eligible for further unification but won't be
// re-quantified by `generalize` at the same level.
pub fn specialize(self: &Engine, s: &Scheme) Ty {
    if s.quantified.len() == 0 {
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
    if s.quantified.len() == 0 {
        return s.body
    }
    for old_id in s.quantified {
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

fn record_binding_undo(self: &Engine, var_id: VarId) {
    self.binding_undo.peek_ref() match {
        Some(frame) => frame.push(BindingUndo {
            var_id = var_id,
            prev = self.bindings.get(var_id),
        })
        None => {}
    }
}

fn record_prim_undo(self: &Engine, var_id: VarId) {
    self.prim_undo.peek_ref() match {
        Some(frame) => frame.push(PrimConstraintUndo {
            var_id = var_id,
            prev = self.prim_constraints.get(var_id),
        })
        None => {}
    }
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
    self.level_undo.peek_ref() match {
        Some(frame) => frame.push(LevelUndo {
            var_id = var_id,
            prev = self.levels.get(var_id),
        })
        None => {}
    }
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
    assert_true(scheme.quantified.len() == 1, "one quantified var")
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
