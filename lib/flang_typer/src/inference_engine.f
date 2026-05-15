// Hindley-Milner unification, fresh-var allocation, level tracking,
// generalisation, specialisation.
//
// The engine returns `UnifyOutcome` values — never diagnostics. Callers
// translate outcomes via `reporter.f` and attach their own context
// (span, error code, message template).
//
// State:
//   - `uf`               equivalence partitions over `VarId`
//   - `bindings`         each (rep) var → its bound `Ty` (another var or concrete)
//   - `prim_constraints` narrowed vars: rep → allowed `PrimitiveKind` set
//   - `binding_undo` / `prim_undo` parallel undo stacks for speculative regions
//   - `level`            cursor for let-generalisation (`enter_level` / `exit_level`)
//   - `var_counter`      next `VarId` (engine-owned; not a global)
//   - `allocator`        used to box `Ref` / `Array.elem` / `Func.ret` payloads
//
// A speculative region (`push_checkpoint` … `rollback` / `commit`) snapshots
// every piece of mutable state so `try_unify` can abandon a unification
// completely. The undo stacks mirror the union-find's own stack frame-
// for-frame, so all three roll back together in one operation.

import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.stack
import flang_typer.type
import flang_typer.scheme
import flang_typer.substitution
import flang_typer.union_find
import flang_typer.coercion
import flang_typer.nominal_registry

// ─────────────────────────────────────────────────────────────────────
// UnifyOutcome — structured result, no diagnostics
// ─────────────────────────────────────────────────────────────────────

pub type UnifyOk = struct {
    ty: Ty
    cost: u32         // number of coercions applied; 0 for pure structural unification
}

// Two concrete types disagreed at a leaf. The engine returns the
// originating pair — not the sub-types of nested mismatches — so the
// reporter can present "expected `T`, got `U`" with the values the
// caller actually wrote. Nested unifications stop at the first leaf
// failure and propagate this same outcome upward.
pub type Mismatch = struct {
    actual: Ty
    expected: Ty
}

pub type OccursDetails = struct {
    var_id: VarId
    ty: Ty
}

// What kind of arity disagreed. Distinguished so the reporter can
// phrase the error in domain terms (function vs tuple vs nominal etc.).
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
    allowed: List(PrimitiveKind)
}

// Variant prefix `Uni` keeps these out of the global variant namespace
// where stdlib's `Result.Ok` / `Option.Some` already live. FLang resolves
// unqualified variants ahead of same-named types across every imported
// module, so a bare `Ok` here would silently win over `Result.Ok` at
// consumer sites and break completely unrelated stdlib code.
pub type UnifyOutcome = enum {
    Unified(UnifyOk)
    UniMismatch(Mismatch)
    UniOccursCheck(OccursDetails)
    UniArityMismatch(ArityDetails)
    UniPrimConstraint(PrimViolation)
}

pub fn is_ok(self: &UnifyOutcome) bool {
    return self.* match {
        Unified(_) => true,
        _ => false,
    }
}

// ─────────────────────────────────────────────────────────────────────
// Speculative-region undo entries
// ─────────────────────────────────────────────────────────────────────

// Records one mutation of `bindings`. `prev` is `Some(old)` when the
// entry overwrote an existing binding, `None` when it was a fresh
// insert (so rollback removes the entry instead of restoring a value).
type BindingUndo = struct {
    var_id: VarId
    prev: Ty?
}

type PrimConstraintUndo = struct {
    var_id: VarId
    prev: List(PrimitiveKind)?    // null = the entry was new (rollback deletes)
}

// One mutation of `levels`. Mirrors `BindingUndo`: `prev` distinguishes
// overwrite (restore) from insert (delete on rollback).
type LevelUndo = struct {
    var_id: VarId
    prev: Level?
}

// ─────────────────────────────────────────────────────────────────────
// Engine
// ─────────────────────────────────────────────────────────────────────

pub type Engine = struct {
    uf: UnionFind(VarId)
    bindings: Dict(VarId, Ty)
    prim_constraints: Dict(VarId, List(PrimitiveKind))
    // Level per partition, keyed by representative `VarId`. The rep's
    // level is the *minimum* of every member's original level so that
    // `generalize` doesn't accidentally quantify a var that was unified
    // with a shallower-scope var. Without this, `resolve_var` would
    // return whatever level the caller happened to pass in — soundness
    // bug for let-polymorphism.
    levels: Dict(VarId, Level)

    binding_undo: Stack(List(BindingUndo))
    prim_undo: Stack(List(PrimConstraintUndo))
    level_undo: Stack(List(LevelUndo))

    var_counter: u32
    level: Level
    // Nominal-aware coercion rules need to resolve well-known FQNs
    // (Option, String, Slice, Type). The checker calls
    // `set_nominal_registry` after `collect_nominals` finishes; until
    // then nominal-aware rules silently no-op.
    nominals: &NominalRegistry?
    allocator: &Allocator
}

pub fn engine(allocator: &Allocator? = null) Engine {
    let alloc = allocator.or_global()
    let uf: UnionFind(VarId) = union_find(alloc)
    let bindings: Dict(VarId, Ty) = dict(alloc)
    let prim_constraints: Dict(VarId, List(PrimitiveKind)) = dict(alloc)
    let levels: Dict(VarId, Level) = dict(alloc)
    let bu: Stack(List(BindingUndo)) = stack(0, alloc)
    let pu: Stack(List(PrimConstraintUndo)) = stack(0, alloc)
    let lu: Stack(List(LevelUndo)) = stack(0, alloc)
    return .{
        uf = uf,
        bindings = bindings,
        prim_constraints = prim_constraints,
        levels = levels,
        binding_undo = bu,
        prim_undo = pu,
        level_undo = lu,
        var_counter = 0u32,
        level = 0u32,
        nominals = null,
        allocator = alloc,
    }
}

// Wire the nominal registry into the engine. Coercion rules that
// resolve well-known FQNs (Option, String, Slice, Type) start firing
// after this is set; before, they silently no-op so plain
// HM-without-sugar works in isolation.
pub fn set_nominal_registry(self: &Engine, reg: &NominalRegistry) {
    self.nominals = reg
}

pub fn deinit(self: &Engine) {
    self.uf.deinit()
    self.bindings.deinit()
    self.prim_constraints.deinit()
    self.levels.deinit()
    // Drain undo stacks — each frame is its own list with its own buffer.
    loop {
        self.binding_undo.pop() match {
            Some(frame) => { let f = frame; f.deinit() },
            None => break,
        }
    }
    self.binding_undo.deinit()
    loop {
        self.prim_undo.pop() match {
            Some(frame) => { let f = frame; f.deinit() },
            None => break,
        }
    }
    self.prim_undo.deinit()
    loop {
        self.level_undo.pop() match {
            Some(frame) => { let f = frame; f.deinit() },
            None => break,
        }
    }
    self.level_undo.deinit()
}

// ─────────────────────────────────────────────────────────────────────
// Level management — let-generalisation cursor
// ─────────────────────────────────────────────────────────────────────

pub fn enter_level(self: &Engine) {
    self.level = self.level + 1u32
}

pub fn exit_level(self: &Engine) {
    if self.level == 0u32 { panic("exit_level: level underflow") }
    self.level = self.level - 1u32
}

// ─────────────────────────────────────────────────────────────────────
// Fresh variables
// ─────────────────────────────────────────────────────────────────────

pub fn fresh_var(self: &Engine) Ty {
    let id = self.var_counter
    self.var_counter = id + 1u32
    set_level(self, id, self.level)
    return Ty.Var(TyVar { id = id, level = self.level })
}

// Allocate a fresh variable whose eventual binding must be one of the
// given primitive kinds. Used to narrow char/byte literals to `{u8, char}`
// so they can't accidentally bind to `String` etc. during overload
// resolution.
pub fn fresh_constrained_var(self: &Engine, allowed: List(PrimitiveKind)) Ty {
    let t = self.fresh_var()
    let v = t match {
        Var(tv) => tv,
        _ => panic("fresh_var didn't return Var"),
    }
    set_prim_constraint(self, v.id, allowed)
    return t
}

// ─────────────────────────────────────────────────────────────────────
// Boxed-payload constructors
//
// `Ref`, `Array.elem`, and `Func.ret` carry their inner `Ty` behind a
// `&Ty` because each holds exactly one. The engine owns the allocator,
// so these helpers belong here and not in `type.f`.
// ─────────────────────────────────────────────────────────────────────

pub fn mk_ref(self: &Engine, inner: Ty) Ty {
    let boxed = box(self.allocator, inner)
    return Ty.Ref(boxed)
}

pub fn mk_array(self: &Engine, elem: Ty, length: usize) Ty {
    let boxed = box(self.allocator, elem)
    return Ty.Array(.{ elem = boxed, length = length })
}

pub fn mk_func(self: &Engine, params: List(Ty), ret: Ty) Ty {
    let boxed_ret = box(self.allocator, ret)
    return Ty.Func(.{ params = params, ret = boxed_ret })
}

// ─────────────────────────────────────────────────────────────────────
// Resolution
//
// `resolve` walks the binding chain for a `Var`; deeper sub-types are
// untouched. `zonk` recursively resolves the entire tree, returning a
// `Ty` with no remaining bound vars (unbound vars stay as `Var`).
// ─────────────────────────────────────────────────────────────────────

pub fn resolve(self: &Engine, t: Ty) Ty {
    return t match {
        Var(v) => resolve_var(self, v),
        _ => t,
    }
}

fn resolve_var(self: &Engine, v: TyVar) Ty {
    let rep = self.uf.find(v.id)
    let bound = self.bindings.get(rep)
    return bound match {
        Some(inner) => self.resolve(inner),
        None => {
            // Authoritative level lives on the rep, not the input var:
            // after `unify_var_var` merges partitions at different
            // levels, only the rep's slot reflects the partition-wide
            // min level used by `generalize`.
            let lvl = self.levels.get(rep) match {
                Some(l) => l,
                None => v.level,
            }
            Ty.Var(.{ id = rep, level = lvl })
        },
    }
}

pub fn zonk(self: &Engine, t: Ty) Ty {
    let r = self.resolve(t)
    return r match {
        Var(_) => r,
        Prim(_) => r,
        Ref(inner) => self.mk_ref(self.zonk(inner.*)),
        Array(arr) => self.mk_array(self.zonk(arr.elem.*), arr.length),
        Func(fn_ty) => zonk_func(self, &fn_ty),
        Tuple(elems) => zonk_tuple(self, &elems),
        Record(fields) => zonk_record(self, &fields),
        Nominal(nr) => zonk_nominal(self, &nr),
        Never => r,
        Void => r,
        Error => r,
    }
}

fn zonk_func(self: &Engine, fn_ty: &FunctionTy) Ty {
    let new_params = list(fn_ty.params.len, self.allocator)
    for i in 0..fn_ty.params.len {
        let p = &fn_ty.params[i]
        new_params.push(self.zonk(p.*))
    }
    return self.mk_func(new_params, self.zonk(fn_ty.ret.*))
}

fn zonk_tuple(self: &Engine, elems: &List(Ty)) Ty {
    let new_elems = list(elems.len, self.allocator)
    for i in 0..elems.len {
        let e = &elems[i]
        new_elems.push(self.zonk(e.*))
    }
    return Ty.Tuple(new_elems)
}

fn zonk_record(self: &Engine, fields: &List(Field)) Ty {
    let new_fields = list(fields.len, self.allocator)
    for i in 0..fields.len {
        let f = &fields[i]
        new_fields.push(Field { name = f.name, ty = self.zonk(f.ty) })
    }
    return Ty.Record(new_fields)
}

fn zonk_nominal(self: &Engine, nr: &NominalRef) Ty {
    if nr.args.len == 0 {
        return Ty.Nominal(.{ id = nr.id, args = nr.args })
    }
    let new_args: List(Ty) = list(nr.args.len, self.allocator)
    for i in 0..nr.args.len {
        let a = &nr.args[i]
        new_args.push(self.zonk(a.*))
    }
    return Ty.Nominal(.{ id = nr.id, args = new_args })
}

// ─────────────────────────────────────────────────────────────────────
// Occurs check — does `v` appear anywhere inside `t`?
// ─────────────────────────────────────────────────────────────────────

pub fn occurs_in(self: &Engine, v: VarId, t: Ty) bool {
    let r = self.resolve(t)
    return r match {
        Var(other) => self.uf.find(other.id) == self.uf.find(v),
        Ref(inner) => self.occurs_in(v, inner.*),
        Array(arr) => self.occurs_in(v, arr.elem.*),
        Func(fn_ty) => occurs_in_func(self, v, &fn_ty),
        Tuple(elems) => occurs_in_list(self, v, &elems),
        Record(fields) => occurs_in_record(self, v, &fields),
        Nominal(nr) => occurs_in_list(self, v, &nr.args),
        _ => false,
    }
}

fn occurs_in_func(self: &Engine, v: VarId, fn_ty: &FunctionTy) bool {
    for i in 0..fn_ty.params.len {
        let p = &fn_ty.params[i]
        if self.occurs_in(v, p.*) { return true }
    }
    return self.occurs_in(v, fn_ty.ret.*)
}

fn occurs_in_list(self: &Engine, v: VarId, items: &List(Ty)) bool {
    for i in 0..items.len {
        let it = &items[i]
        if self.occurs_in(v, it.*) { return true }
    }
    return false
}

fn occurs_in_record(self: &Engine, v: VarId, fields: &List(Field)) bool {
    for i in 0..fields.len {
        let f = &fields[i]
        if self.occurs_in(v, f.ty) { return true }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────
// Unification
// ─────────────────────────────────────────────────────────────────────

// Unify `actual` into `expected`. Returns `Ok(UnifyOk { ty, cost })`
// on success — `ty` is the unified type and `cost` counts applied
// coercions (always 0 in this pure-structural pass; coercion rules
// land in a follow-up). Any failure short-circuits and returns a
// structured outcome without mutating engine state.
//
// `actual` flowing into `expected` is the direction coercion rules
// will eventually respect (integer widening, `T → Option(T)`, etc.).
// Structural unification is direction-insensitive.
pub fn unify(self: &Engine, actual: Ty, expected: Ty) UnifyOutcome {
    let a = self.resolve(actual)
    let b = self.resolve(expected)
    return unify_resolved(self, a, b)
}

fn unify_resolved(self: &Engine, a: Ty, b: Ty) UnifyOutcome {
    // Error is poison — absorbs anything silently.
    if a.is_error() or b.is_error() { return UnifyOutcome.Unified(.{ ty = Ty.Error, cost = 0 }) }
    // Never is bottom — unifies with everything, taking the other type.
    if a.is_never() { return UnifyOutcome.Unified(.{ ty = b, cost = 0 }) }
    if b.is_never() { return UnifyOutcome.Unified(.{ ty = a, cost = 0 }) }

    // Both vars — merge their partitions. The first arg's rep wins
    // (matches the union-find contract) so concrete types accumulated
    // by earlier unifications stay reachable.
    return a match {
        Var(va) => b match {
            Var(vb) => unify_var_var(self, va, vb),
            _ => bind_var(self, va, b),
        },
        _ => b match {
            Var(vb) => bind_var(self, vb, a),
            _ => unify_concrete(self, a, b),
        },
    }
}

// Both sides concrete (no Var, no Never, no Error). Try structural
// unification first; on mismatch, fall through to the directional
// coercion ladder. `actual = a` flows into `expected = b`.
fn unify_concrete(self: &Engine, a: Ty, b: Ty) UnifyOutcome {
    let structural = unify_structural(self, a, b)
    if structural.is_ok() { return structural }

    let coerced = try_coercion(self, a, b)
    return coerced match {
        Some(c) => apply_coercion(self, c, structural),
        None => structural,
    }
}

// Walk the hardcoded coercion ladder for `(from, to)`. First rule that
// fires wins; ordering matters when two rules could both apply. Returns
// `null` when nothing matches — the caller propagates the original
// structural failure.
//
// Order: pure prim rules first (integer widening, float widening),
// then nominal-aware rules in the order most callers expect (option
// wrapping has the highest hit rate, then string→byte-slice, then
// array decay and slice-to-ref, then the `Type(T)` lift).
fn try_coercion(self: &Engine, from: Ty, to: Ty) Coercion? {
    let r1 = try_integer_widening(from, to, self.allocator)
    if r1.is_some() { return r1 }
    let r2 = try_float_widening(from, to, self.allocator)
    if r2.is_some() { return r2 }
    self.nominals match {
        Some(reg) => {
            let r3 = try_option_wrapping(from, to, reg, self.allocator)
            if r3.is_some() { return r3 }
            let r4 = try_string_to_byte_slice(from, to, reg, self.allocator)
            if r4.is_some() { return r4 }
            let r5 = try_array_decay(from, to, reg, self.allocator)
            if r5.is_some() { return r5 }
            let r6 = try_slice_to_reference(from, to, reg, self.allocator)
            if r6.is_some() { return r6 }
            let r7 = try_nominal_to_type(from, to, reg, self.allocator)
            if r7.is_some() { return r7 }
        },
        None => {},
    }
    return null
}

// Commit a coercion atomically: open a checkpoint, run every side-
// unification through the main `unify` loop, commit on full success,
// roll back on any failure. The checkpoint guarantees a partially-
// applied coercion can never leak state — whether or not the caller
// has its own outer checkpoint open.
//
// On rollback the original `fallback` outcome is returned so the
// reporter surfaces the leaf mismatch the caller actually wrote, not
// some derived side-unification failure.
fn apply_coercion(self: &Engine, c: Coercion, fallback: UnifyOutcome) UnifyOutcome {
    self.push_checkpoint()
    for i in 0..c.side_unifications.len {
        let con = &c.side_unifications[i]
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
    if ra == rb { return UnifyOutcome.Unified(.{ ty = Ty.Var(va), cost = 0 }) }

    // Intersect prim constraints, if any. An empty intersection means
    // the two narrow sets are disjoint and the partitions can't merge.
    let merged_constraint = intersect_prim_constraints(self, ra, rb)
    if merged_constraint.is_some() and merged_constraint.unwrap().len == 0 {
        return UnifyOutcome.UniPrimConstraint(.{
            got = Ty.Var(va),
            allowed = list(0, self.allocator),
        })
    }

    // Compute the merged level *before* the merge — both reps still
    // have their own slots at this point. Use the min so the partition
    // stays generalisable only from the outer-most binding scope.
    let level_a = self.levels.get(ra) match { Some(l) => l, None => self.level }
    let level_b = self.levels.get(rb) match { Some(l) => l, None => self.level }
    let merged_level = if level_a < level_b { level_a } else { level_b }

    self.uf.merge(ra, rb)
    let new_rep = self.uf.find(ra)
    // Apply the merged constraint to the new rep; clear the loser.
    let loser = if new_rep == ra { rb } else { ra }
    clear_prim_constraint(self, loser)
    merged_constraint match {
        Some(allowed) => set_prim_constraint(self, new_rep, allowed),
        None => {},
    }
    // Stamp the merged level onto the rep and drop the loser's slot.
    set_level(self, new_rep, merged_level)
    clear_level(self, loser)
    return UnifyOutcome.Unified(.{ ty = Ty.Var(va), cost = 0 })
}

fn bind_var(self: &Engine, v: TyVar, concrete: Ty) UnifyOutcome {
    let rep = self.uf.find(v.id)

    if self.occurs_in(rep, concrete) {
        return UnifyOutcome.UniOccursCheck(.{ var_id = rep, ty = concrete })
    }

    // Honour prim constraint, if any.
    let constraint = self.prim_constraints.get(rep)
    constraint match {
        Some(allowed) => {
            let violation = check_prim_constraint(&allowed, concrete)
            if violation.is_some() { return violation.unwrap() }
            clear_prim_constraint(self, rep)
        },
        None => {},
    }

    record_binding_undo(self, rep)
    self.bindings.set(rep, concrete)
    return UnifyOutcome.Unified(.{ ty = concrete, cost = 0 })
}

// Returns `Some(PrimConstraint(...))` if `concrete` violates `allowed`,
// `None` otherwise. `allowed` is owned by the caller; the violation
// payload aliases its buffer (the engine never mutates allowed-lists
// after they're set on a var).
fn check_prim_constraint(allowed: &List(PrimitiveKind), concrete: Ty) UnifyOutcome? {
    let satisfied = concrete match {
        Prim(p) => prim_set_contains(allowed, p),
        _ => false,
    }
    if satisfied { return null }
    return UnifyOutcome.UniPrimConstraint(PrimViolation {
        got = concrete,
        allowed = allowed.*,
    })
}

fn prim_set_contains(allowed: &List(PrimitiveKind), p: PrimitiveKind) bool {
    for i in 0..allowed.len {
        let k = allowed[i]
        if k == p { return true }
    }
    return false
}

fn make_mismatch(a: Ty, b: Ty) UnifyOutcome {
    return UnifyOutcome.UniMismatch(Mismatch { actual = a, expected = b })
}

fn make_ok(ty: Ty) UnifyOutcome {
    return UnifyOutcome.Unified(UnifyOk { ty = ty, cost = 0u32 })
}

fn unify_structural(self: &Engine, a: Ty, b: Ty) UnifyOutcome {
    return a match {
        Prim(pa) => unify_a_prim(pa, a, b),
        Ref(ia) => unify_a_ref(self, ia, a, b),
        Array(aa) => unify_a_array(self, &aa, a, b),
        Func(fa) => unify_a_func(self, &fa, a, b),
        Tuple(ta) => unify_a_tuple(self, &ta, a, b),
        Record(ra) => unify_a_record(self, &ra, a, b),
        Nominal(na) => unify_a_nominal(self, &na, a, b),
        Void => unify_a_void(a, b),
        _ => make_mismatch(a, b),
    }
}

fn unify_a_prim(pa: PrimitiveKind, a: Ty, b: Ty) UnifyOutcome {
    return b match {
        Prim(pb) => if pa == pb { make_ok(a) } else { make_mismatch(a, b) },
        _ => make_mismatch(a, b),
    }
}

fn unify_a_ref(self: &Engine, ia: &Ty, a: Ty, b: Ty) UnifyOutcome {
    return b match {
        Ref(ib) => unify_refs(self, ia, ib, a),
        _ => make_mismatch(a, b),
    }
}

fn unify_refs(self: &Engine, ia: &Ty, ib: &Ty, a: Ty) UnifyOutcome {
    let r = self.unify(ia.*, ib.*)
    if r.is_ok() { return make_ok(a) }
    return r
}

fn unify_a_array(self: &Engine, aa: &ArrayTy, a: Ty, b: Ty) UnifyOutcome {
    return b match {
        Array(ab) => unify_arrays(self, aa, &ab, a),
        _ => make_mismatch(a, b),
    }
}

fn unify_arrays(self: &Engine, aa: &ArrayTy, ab: &ArrayTy, a: Ty) UnifyOutcome {
    if aa.length != ab.length {
        return UnifyOutcome.UniArityMismatch(.{
            what = ArityKind.ArrayLength,
            expected = ab.length,
            actual = aa.length,
        })
    }
    let r = self.unify(aa.elem.*, ab.elem.*)
    if r.is_ok() { return make_ok(a) }
    return r
}

fn unify_a_func(self: &Engine, fa: &FunctionTy, a: Ty, b: Ty) UnifyOutcome {
    return b match {
        Func(fb) => unify_func(self, fa, &fb, a, b),
        _ => make_mismatch(a, b),
    }
}

fn unify_a_tuple(self: &Engine, ta: &List(Ty), a: Ty, b: Ty) UnifyOutcome {
    return b match {
        Tuple(tb) => unify_lists(self, ta, &tb, a, b, ArityKind.TupleLength),
        Void => if ta.len == 0 { make_ok(b) } else { make_mismatch(a, b) },
        _ => make_mismatch(a, b),
    }
}

fn unify_a_record(self: &Engine, ra: &List(Field), a: Ty, b: Ty) UnifyOutcome {
    return b match {
        Record(rb) => unify_record(self, ra, &rb, a, b),
        _ => make_mismatch(a, b),
    }
}

fn unify_a_nominal(self: &Engine, na: &NominalRef, a: Ty, b: Ty) UnifyOutcome {
    return b match {
        Nominal(nb) => unify_nominal(self, na, &nb, a, b),
        _ => make_mismatch(a, b),
    }
}

fn unify_a_void(a: Ty, b: Ty) UnifyOutcome {
    return b match {
        Void => make_ok(a),
        Tuple(tb) => if tb.len == 0 { make_ok(a) } else { make_mismatch(a, b) },
        _ => make_mismatch(a, b),
    }
}

fn unify_func(self: &Engine, fa: &FunctionTy, fb: &FunctionTy, a: Ty, b: Ty) UnifyOutcome {
    if fa.params.len != fb.params.len {
        return UnifyOutcome.UniArityMismatch(.{
            what = ArityKind.FuncParams,
            expected = fb.params.len,
            actual = fa.params.len,
        })
    }
    for i in 0..fa.params.len {
        let pa = &fa.params[i]
        let pb = &fb.params[i]
        let r = self.unify(pa.*, pb.*)
        if !r.is_ok() { return r }
    }
    let rr = self.unify(fa.ret.*, fb.ret.*)
    if rr.is_ok() { return make_ok(a) }
    return rr
}

fn unify_lists(self: &Engine, ta: &List(Ty), tb: &List(Ty), a: Ty, b: Ty, what: ArityKind) UnifyOutcome {
    if ta.len != tb.len {
        return UnifyOutcome.UniArityMismatch(.{
            what = what,
            expected = tb.len,
            actual = ta.len,
        })
    }
    for i in 0..ta.len {
        let ea = &ta[i]
        let eb = &tb[i]
        let r = self.unify(ea.*, eb.*)
        if !r.is_ok() { return r }
    }
    return make_ok(a)
}

fn unify_record(self: &Engine, ra: &List(Field), rb: &List(Field), a: Ty, b: Ty) UnifyOutcome {
    if ra.len != rb.len {
        return UnifyOutcome.UniArityMismatch(.{
            what = ArityKind.RecordFields,
            expected = rb.len,
            actual = ra.len,
        })
    }
    for i in 0..ra.len {
        let fa = &ra[i]
        let fb = &rb[i]
        if fa.name != fb.name { return make_mismatch(a, b) }
        let r = self.unify(fa.ty, fb.ty)
        if !r.is_ok() { return r }
    }
    return make_ok(a)
}

fn unify_nominal(self: &Engine, na: &NominalRef, nb: &NominalRef, a: Ty, b: Ty) UnifyOutcome {
    if na.id != nb.id { return make_mismatch(a, b) }
    if na.args.len != nb.args.len {
        return UnifyOutcome.UniArityMismatch(.{
            what = ArityKind.NominalArgs,
            expected = nb.args.len,
            actual = na.args.len,
        })
    }
    for i in 0..na.args.len {
        let aa = &na.args[i]
        let bb = &nb.args[i]
        let r = self.unify(aa.*, bb.*)
        if !r.is_ok() { return r }
    }
    return make_ok(a)
}

// ─────────────────────────────────────────────────────────────────────
// try_unify — speculative, always rolled back
// ─────────────────────────────────────────────────────────────────────

// Run `unify` inside a fresh checkpoint and discard every mutation
// regardless of outcome. Used by overload resolution and coercion-rule
// scoring to probe a candidate without committing. The returned
// `UnifyOutcome` is informational only — vars are not actually bound.
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
        if i == 0 { break }
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
        if j == 0 { break }
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
        if k == 0 { break }
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
// Scheme operations — generalise and specialise
// ─────────────────────────────────────────────────────────────────────

// Quantify every free variable of `t` whose level is deeper than the
// engine's current cursor. `t` is zonked first so any chain of bound
// vars is collapsed before the free-var walk.
pub fn generalize(self: &Engine, t: Ty) Scheme {
    let z = self.zonk(t)
    let quantified: Set(VarId) = set(self.allocator)
    free_vars(&z, self.level, &quantified)
    return .{ quantified = quantified, body = z }
}

// Instantiate `s` with engine-fresh variables substituted for every
// quantified id. The fresh vars carry the engine's current level —
// they're eligible for further unification but won't be re-quantified
// by `generalize` at the same level.
pub fn specialize(self: &Engine, s: &Scheme) Ty {
    if s.quantified.len() == 0 { return s.body }
    let subst: Dict(VarId, Ty) = dict(self.allocator)
    for old_id in s.quantified {
        let fresh = self.fresh_var()
        subst.set(old_id, fresh)
    }
    return substitute(&s.body, &subst, self.allocator)
}

// ─────────────────────────────────────────────────────────────────────
// Internal — prim-constraint bookkeeping
// ─────────────────────────────────────────────────────────────────────

fn set_prim_constraint(self: &Engine, var_id: VarId, allowed: List(PrimitiveKind)) {
    record_prim_undo(self, var_id)
    self.prim_constraints.set(var_id, allowed)
}

fn clear_prim_constraint(self: &Engine, var_id: VarId) {
    if !self.prim_constraints.contains(var_id) { return }
    record_prim_undo(self, var_id)
    self.prim_constraints.remove(var_id)
}

// Intersect the prim-constraint sets attached to two rep vars. Returns
// `None` when neither var is constrained (so the merge places no
// further restriction on the partition), `Some(intersection)` otherwise
// — the intersection may be empty, signalling an incompatible merge.
fn intersect_prim_constraints(self: &Engine, ra: VarId, rb: VarId) List(PrimitiveKind)? {
    let ca = self.prim_constraints.get(ra)
    let cb = self.prim_constraints.get(rb)
    if ca.is_none() and cb.is_none() { return null }
    if ca.is_none() { return cb }
    if cb.is_none() { return ca }
    let xa = ca.unwrap()
    let xb = cb.unwrap()
    let out = list(0, self.allocator)
    for i in 0..xa.len {
        let k = xa[i]
        for j in 0..xb.len {
            let k2 = xb[j]
            if k == k2 { out.push(k); break }
        }
    }
    return out
}

fn record_binding_undo(self: &Engine, var_id: VarId) {
    self.binding_undo.peek_ref() match {
        Some(frame) => frame.push(BindingUndo {
            var_id = var_id,
            prev = self.bindings.get(var_id),
        }),
        None => {},
    }
}

fn record_prim_undo(self: &Engine, var_id: VarId) {
    self.prim_undo.peek_ref() match {
        Some(frame) => frame.push(PrimConstraintUndo {
            var_id = var_id,
            prev = self.prim_constraints.get(var_id),
        }),
        None => {},
    }
}

fn set_level(self: &Engine, var_id: VarId, lvl: Level) {
    record_level_undo(self, var_id)
    self.levels.set(var_id, lvl)
}

fn clear_level(self: &Engine, var_id: VarId) {
    if !self.levels.contains(var_id) { return }
    record_level_undo(self, var_id)
    self.levels.remove(var_id)
}

fn record_level_undo(self: &Engine, var_id: VarId) {
    self.level_undo.peek_ref() match {
        Some(frame) => frame.push(LevelUndo {
            var_id = var_id,
            prev = self.levels.get(var_id),
        }),
        None => {},
    }
}
