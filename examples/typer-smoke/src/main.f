// Smoke test for the flang_typer data + engine layers.

// Smoke covers the data layer + engine + coercion. The higher layers
// (env, nominal_registry, function_registry, inference_results,
// specialization, checker, result) compile cleanly as a library but
// cannot yet be imported into a consuming project — the C# compiler's
// RTTI emission walks generic structs declared as struct fields
// (e.g. `Stack(Scope)` with `Scope.bindings: Dict(String, Binding)`)
// and emits typeinfo entries for the *un-instantiated* templates,
// producing C identifiers like `__flang__typeinfo_std_dict_Entry_$K_$V`
// and `__flang__typeinfo_std_dict_Dict_?25_u8` that don't compile.
// Tracked as a follow-up; the typer lib itself is feature-complete.

import std.set
import flang_typer.type
import flang_typer.well_known
import flang_typer.scheme
import flang_typer.substitution
import flang_typer.union_find
import flang_typer.inference_engine

fn check(cond: bool, tag: String, failures: &i32) {
    if !cond {
        failures.* = failures.* + 1i32
        println($"  FAIL: {tag}")
    }
}

pub fn main() i32 {
    let failures: i32 = 0i32

    // ── Data layer ───────────────────────────────────────────────────

    let a = ty_i32()
    let b = ty_i32()
    check(equals(&a, &b), "prim_eq_same", &failures)
    let c = ty_i64()
    check(!equals(&a, &c), "prim_eq_diff", &failures)

    let v1: Ty = Ty.Var(TyVar { id = 1u32, level = 0u32 })
    let v1b: Ty = Ty.Var(TyVar { id = 1u32, level = 7u32 })
    let v2: Ty = Ty.Var(TyVar { id = 2u32, level = 0u32 })
    check(equals(&v1, &v1b), "var_eq_same_id_diff_level", &failures)
    check(!equals(&v1, &v2), "var_eq_diff_id", &failures)

    let empty_tuple: Ty = Ty.Tuple(list(0))
    let void_ty: Ty = ty_void()
    check(equals(&empty_tuple, &void_ty), "empty_tuple_eq_void", &failures)
    check(equals(&void_ty, &empty_tuple), "void_eq_empty_tuple", &failures)

    let body_var: Ty = Ty.Var(TyVar { id = 42u32, level = 3u32 })
    let outer_var: Ty = Ty.Var(TyVar { id = 7u32, level = 1u32 })
    let inner: List(Ty) = list(2)
    inner.push(body_var)
    inner.push(outer_var)
    let body: Ty = Ty.Tuple(inner)
    let free: Set(VarId) = set()
    free_vars(&body, 2u32, &free)
    check(free.len() == 1, "free_vars_count", &failures)
    check(free.contains(42u32), "free_vars_has_deep", &failures)
    check(!free.contains(7u32), "free_vars_excludes_shallow", &failures)

    let uf: UnionFind(u32) = union_find()
    uf.merge(1u32, 2u32)
    uf.merge(2u32, 3u32)
    check(uf.find(3u32) == 1u32, "uf_chain_find", &failures)
    uf.push_checkpoint()
    uf.merge(1u32, 4u32)
    check(uf.find(4u32) == 1u32, "uf_speculative_merge", &failures)
    uf.rollback()
    check(uf.find(4u32) == 4u32, "uf_rollback_isolates", &failures)
    check(uf.find(3u32) == 1u32, "uf_rollback_preserves", &failures)

    // ── Engine layer ─────────────────────────────────────────────────

    let eng = engine()

    let fv1 = eng.fresh_var()
    let fv2 = eng.fresh_var()
    let id1 = fv1 match { Var(tv) => tv.id, _ => 999u32 }
    let id2 = fv2 match { Var(tv) => tv.id, _ => 999u32 }
    check(id1 != id2, "fresh_var_unique", &failures)

    let i32_ty = ty_i32()
    let out1 = eng.unify(fv1, i32_ty)
    check(out1.is_ok(), "unify_var_concrete_ok", &failures)
    let resolved1 = eng.resolve(fv1)
    check(equals(&resolved1, &i32_ty), "resolve_after_bind", &failures)

    let out_same = eng.unify(ty_bool(), ty_bool())
    check(out_same.is_ok(), "unify_concrete_same", &failures)
    let out_diff = eng.unify(ty_bool(), ty_i32())
    // bool → i32 widens (bool participates in the integer widening ladder).
    check(out_diff.is_ok(), "unify_bool_widens_to_i32", &failures)

    // Coercion: integer widening succeeds, narrowing fails.
    let widen_ok = eng.unify(ty_i8(), ty_i32())
    check(widen_ok.is_ok(), "i8_widens_to_i32", &failures)
    let widen_cost = widen_ok match {
        Unified(uo) => uo.cost,
        _ => 0u32,
    }
    check(widen_cost == 1u32, "widening_costs_one", &failures)

    let narrow = eng.unify(ty_i64(), ty_i32())
    check(!narrow.is_ok(), "i64_does_not_narrow_to_i32", &failures)

    // Float widening: f32 → f64 ok, f64 → f32 not ok.
    let f_widen = eng.unify(ty_f32(), ty_f64())
    check(f_widen.is_ok(), "f32_widens_to_f64", &failures)
    let f_narrow = eng.unify(ty_f64(), ty_f32())
    check(!f_narrow.is_ok(), "f64_does_not_narrow_to_f32", &failures)

    // Cross-signedness: unsigned → signed with strictly larger rank ok,
    // same-rank or smaller-rank not ok (would reinterpret sign).
    let cross_ok = eng.unify(ty_u8(), ty_i32())
    check(cross_ok.is_ok(), "u8_widens_to_i32", &failures)
    let cross_bad = eng.unify(ty_u32(), ty_i32())
    check(!cross_bad.is_ok(), "u32_no_widen_to_i32_same_rank", &failures)

    let fv_occurs = eng.fresh_var()
    let wrapping = eng.mk_ref(fv_occurs)
    let occurs_outcome = eng.unify(fv_occurs, wrapping)
    let is_occurs = occurs_outcome match { UniOccursCheck(_) => true, _ => false }
    check(is_occurs, "occurs_check", &failures)

    let t2: List(Ty) = list(2); t2.push(ty_i32()); t2.push(ty_bool())
    let t3: List(Ty) = list(3); t3.push(ty_i32()); t3.push(ty_bool()); t3.push(ty_i64())
    let arity_outcome = eng.unify(Ty.Tuple(t2), Ty.Tuple(t3))
    let is_arity = arity_outcome match { UniArityMismatch(_) => true, _ => false }
    check(is_arity, "tuple_arity_mismatch", &failures)

    let fv_spec = eng.fresh_var()
    let speculative = eng.try_unify(fv_spec, ty_i32())
    check(speculative.is_ok(), "try_unify_succeeds", &failures)
    let after_rollback = eng.resolve(fv_spec)
    let still_unbound = after_rollback match { Var(_) => true, _ => false }
    check(still_unbound, "try_unify_rolls_back", &failures)

    // Standard HM pattern: enter the deeper level, allocate inference-only
    // vars inside, exit, then generalise. After exit_level the engine's
    // cursor is back to the outer level, so vars at the inner level are
    // strictly deeper than the cursor and become quantified.
    eng.enter_level()
    let inner_var = eng.fresh_var()
    eng.exit_level()
    let scheme = eng.generalize(inner_var)
    check(scheme.quantified.len() == 1, "generalize_one_quantifier", &failures)
    let inst = eng.specialize(&scheme)
    let inst_id = inst match { Var(tv) => tv.id, _ => 999u32 }
    let orig_id = inner_var match { Var(tv) => tv.id, _ => 998u32 }
    check(inst_id != orig_id, "specialize_fresh_var", &failures)

    if failures == 0i32 {
        println("flang_typer smoke OK")
    } else {
        println($"flang_typer smoke FAIL: {failures} failure(s)")
    }
    return failures
}
