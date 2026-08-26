// Gate A - structural comparison of two `TypeCheckResult`s.
//
// RFC-022 turns the checker incremental: a module is dirtied and
// re-demanded instead of the whole program being re-checked. Nothing in
// the existing gates catches a stale cache entry surviving an
// invalidation - the 551 harness tests and the stage-2 = stage-3 fixpoint
// both run cold, so a graph that never reuses an entry passes all of
// them. Comparing an incremental result against a cold one entry by entry
// is the incremental analogue of that fixpoint.
//
// Two rules shape what "identical" means here:
//
//   - Types compare by their canonical `format` rendering, the same
//     identity `specialization.key_for` hashes on. A type that renders
//     differently IS a different type as far as the rest of the compiler
//     is concerned.
//   - Ids compare by value. A renumbered nominal or specialization is
//     exactly the failure this gate exists to catch, so `Ty.Nominal(7)`
//     against `Ty.Nominal(8)` is a difference even when both name the
//     same declaration.
//
// A dict pair needs only one-directional containment plus equal sizes:
// if every key of A is in B with an equal value and |A| = |B|, the two
// are the same map.
//
// Both sides render their types through B's table. The type table is one
// per project: a re-demand adopts the previous result's table and appends
// to it, which leaves the earlier snapshot's own `interner` field a
// stand-in while its handles stay valid in the table B now holds. Two
// independently-checked results also compare correctly this way only for
// the fixed leaf ids; the gate never compares two of those.

import std.allocator
import std.dict
import std.list
import std.option
import std.set
import std.string
import std.string_builder
import std.test
import flang_core.span
import flang_typer.type
import flang_typer.interner
import flang_typer.node_id
import flang_typer.inference_results
import flang_typer.nominal_registry
import flang_typer.function_registry
import flang_typer.specialization
import flang_typer.result

// How many differences a report spells out before it starts counting
// only. A stale entry usually breaks thousands of nodes at once; the
// first handful say where, the total says how bad.
const MAX_MESSAGES: usize = 20

// The outcome of one comparison. `messages` holds the first
// `MAX_MESSAGES` differences in the order they were found; `total` counts
// every one, so a truncated report still says how much it hid.
pub type ResultDiff = struct {
    messages: List(OwnedString)
    total: usize
}

pub fn deinit(self: &ResultDiff) {
    for &m in self.messages {
        m.deinit()
    }
    self.messages.deinit()
}

// True when the two results were identical across every table compared.
pub fn is_empty(self: &ResultDiff) bool {
    return self.total == 0
}

// Compare every table whose entries other modules' results cite: the two
// registries whose ids are baked into `Ty` and `ResolvedTarget`, the three
// node-keyed tables lowering reads, and the RTTI list lowering indexes
// positionally.
//
// The remaining tables are compared by size only - see `diff_sizes`.
pub fn diff_results(a: &TypeCheckResult, b: &TypeCheckResult, allocator: &Allocator? = null) ResultDiff {
    let messages: List(OwnedString) = list(0, allocator)
    let d = ResultDiff { messages = messages, total = 0 }
    diff_nominals(&d, a, b, allocator)
    diff_functions(&d, a, b, allocator)
    diff_specializations(&d, a, b, allocator)
    diff_node_types(&d, a, b, allocator)
    diff_targets(&d, a, b, allocator)
    diff_ops(&d, a, b, allocator)
    diff_instantiated(&d, a, b, allocator)
    diff_spans(&d, a, b, allocator)
    diff_paths(&d, a, b, allocator)
    diff_sizes(&d, a, b, allocator)
    return d
}

// Record one difference. Past the cap the message is dropped rather than
// stored - the count is what still has to be right.
fn note(d: &ResultDiff, msg: OwnedString) {
    d.total = d.total + 1
    if d.messages.len < MAX_MESSAGES {
        d.messages.push(msg)
        return
    }
    msg.deinit()
}

// ─────────────────────────────────────────────────────────────────────
// Registries
// ─────────────────────────────────────────────────────────────────────

fn diff_nominals(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    let an = a.nominals.next_id
    let bn = b.nominals.next_id
    if an != bn {
        note(d, $"nominals: next_id {an} vs {bn}")
    }
    let hi = if an > bn { an } else { bn }
    let lb = string_builder(64, alloc)
    defer lb.deinit()
    let rb = string_builder(64, alloc)
    defer rb.deinit()
    for i in 0..(hi as usize) {
        let id = i as NominalId
        let left = a.nominals.find(id)
        let right = b.nominals.find(id)
        if left.is_none() and right.is_none() { continue }
        if left.is_none() {
            note(d, $"nominals[{id}]: a hole on the left, present on the right")
            continue
        }
        if right.is_none() {
            note(d, $"nominals[{id}]: present on the left, a hole on the right")
            continue
        }
        lb.clear()
        rb.clear()
        append_nominal(&lb, left.unwrap(), &b.interner)
        append_nominal(&rb, right.unwrap(), &b.interner)
        if lb.as_view() != rb.as_view() {
            note(d, $"nominals[{id}]: {lb.as_view()} vs {rb.as_view()}")
        }
    }
}

// The function registry: overload lists compare positionally per name -
// resolution order is part of the value - and each scheme's id, flags
// and rendered signature must match.
fn diff_functions(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    if a.functions.next_id != b.functions.next_id {
        note(d, $"functions: next_id {a.functions.next_id} vs {b.functions.next_id}")
    }
    if a.functions.by_name.len() != b.functions.by_name.len() {
        note(d, $"functions: {a.functions.by_name.len()} names vs {b.functions.by_name.len()}")
    }
    let lb = string_builder(64, alloc)
    defer lb.deinit()
    let rb = string_builder(64, alloc)
    defer rb.deinit()
    for entry in a.functions.by_name {
        const name = entry.key
        const other = b.functions.by_name.get_ref(name)
        if other.is_none() {
            note(d, $"functions[{name}]: missing on the right")
            continue
        }
        let left: List(FunctionScheme) = entry.value
        let right = other.unwrap()
        if left.len != right.len {
            note(d, $"functions[{name}]: {left.len} overloads vs {right.len}")
            continue
        }
        for j in 0..left.len {
            lb.clear()
            rb.clear()
            append_scheme(&lb, &left[j], &b.interner)
            append_scheme(&rb, &right[j], &b.interner)
            if lb.as_view() != rb.as_view() {
                note(d, $"functions[{name}][{j}]: {lb.as_view()} vs {rb.as_view()}")
            }
        }
    }
}

fn diff_specializations(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    let an = a.specializations.next_id
    let bn = b.specializations.next_id
    if an != bn {
        note(d, $"specializations: next_id {an} vs {bn}")
    }
    let hi = if an > bn { an } else { bn }
    let lb = string_builder(64, alloc)
    defer lb.deinit()
    let rb = string_builder(64, alloc)
    defer rb.deinit()
    for i in 0..(hi as usize) {
        let id = i as u32
        let left = a.specializations.find(id)
        let right = b.specializations.find(id)
        if left.is_none() and right.is_none() { continue }
        if left.is_none() {
            note(d, $"specializations[{id}]: a hole on the left, present on the right")
            continue
        }
        if right.is_none() {
            note(d, $"specializations[{id}]: present on the left, a hole on the right")
            continue
        }
        lb.clear()
        rb.clear()
        append_spec(&lb, left.unwrap(), &b.interner)
        append_spec(&rb, right.unwrap(), &b.interner)
        if lb.as_view() != rb.as_view() {
            note(d, $"specializations[{id}]: {lb.as_view()} vs {rb.as_view()}")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Node-keyed tables
// ─────────────────────────────────────────────────────────────────────

fn diff_node_types(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    let al = a.node_types.len()
    let bl = b.node_types.len()
    if al != bl {
        note(d, $"node_types: {al} entries vs {bl}")
    }
    for e in a.node_types {
        let key = e.key
        let other = b.node_types.get(key)
        if other.is_none() {
            note(d, $"node_types[{key}]: missing on the right")
            continue
        }
        // Both sides render through B's table (see the module header), so
        // ids stay free to differ while the types they name must not.
        const lk = b.interner.key_of(e.value)
        const rk = b.interner.key_of(other.unwrap())
        if lk != rk {
            note(d, $"node_types[{key}]: {lk} vs {rk}")
        }
    }
}

fn diff_targets(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    let al = a.resolved_targets.len()
    let bl = b.resolved_targets.len()
    if al != bl {
        note(d, $"resolved_targets: {al} entries vs {bl}")
    }
    let lb = string_builder(64, alloc)
    defer lb.deinit()
    let rb = string_builder(64, alloc)
    defer rb.deinit()
    for e in a.resolved_targets {
        let key = e.key
        let other = b.resolved_targets.get_ref(key)
        if other.is_none() {
            note(d, $"resolved_targets[{key}]: missing on the right")
            continue
        }
        lb.clear()
        rb.clear()
        let lv = e.value
        append_target(&lb, &lv)
        append_target(&rb, other.unwrap())
        if lb.as_view() != rb.as_view() {
            note(d, $"resolved_targets[{key}]: {lb.as_view()} vs {rb.as_view()}")
        }
    }
}

fn diff_ops(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    let al = a.resolved_ops.len()
    let bl = b.resolved_ops.len()
    if al != bl {
        note(d, $"resolved_ops: {al} entries vs {bl}")
    }
    let lb = string_builder(64, alloc)
    defer lb.deinit()
    let rb = string_builder(64, alloc)
    defer rb.deinit()
    for e in a.resolved_ops {
        let key = e.key
        let other = b.resolved_ops.get_ref(key)
        if other.is_none() {
            note(d, $"resolved_ops[{key}]: missing on the right")
            continue
        }
        lb.clear()
        rb.clear()
        let lv = e.value
        append_op(&lb, &lv)
        append_op(&rb, other.unwrap())
        if lb.as_view() != rb.as_view() {
            note(d, $"resolved_ops[{key}]: {lb.as_view()} vs {rb.as_view()}")
        }
    }
}

// The RTTI table. Lowering indexes it positionally, so order is part of
// the value.
fn diff_instantiated(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    const al = a.instantiated_types.len
    const bl = b.instantiated_types.len
    if al != bl {
        note(d, $"instantiated_types: {al} entries vs {bl}")
    }
    const lo = if al < bl { al } else { bl }
    let lb = string_builder(64, alloc)
    defer lb.deinit()
    let rb = string_builder(64, alloc)
    defer rb.deinit()
    for i in 0..lo {
        lb.clear()
        rb.clear()
        b.interner.format(a.instantiated_types[i], &lb)
        b.interner.format(b.instantiated_types[i], &rb)
        if lb.as_view() != rb.as_view() {
            note(d, $"instantiated_types[{i}]: {lb.as_view()} vs {rb.as_view()}")
        }
    }
}

// The inverse of the node-id fingerprint. Two entries sharing a key must
// name the same span; one that does not is a node whose source moved while
// its id did not.
fn diff_spans(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    let al = a.spans.len()
    let bl = b.spans.len()
    if al != bl {
        note(d, $"spans: {al} entries vs {bl}")
    }
    for e in a.spans {
        let key = e.key
        let other = b.spans.get(key)
        if other.is_none() {
            note(d, $"spans[{key}]: missing on the right")
            continue
        }
        const l = e.value
        const r = other.unwrap()
        if l.file_id != r.file_id or l.start != r.start or l.length != r.length {
            note(d, $"spans[{key}]: {l.file_id}:{l.start}+{l.length} vs {r.file_id}:{r.start}+{r.length}")
        }
    }
}

// File ids index this list, so order is the value.
fn diff_paths(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    const al = a.file_paths.len
    const bl = b.file_paths.len
    if al != bl {
        note(d, $"file_paths: {al} entries vs {bl}")
    }
    const lo = if al < bl { al } else { bl }
    for i in 0..lo {
        const lp = a.file_paths[i].as_view()
        const rp = b.file_paths[i].as_view()
        if lp != rp {
            note(d, $"file_paths[{i}]: {lp} vs {rp}")
        }
    }
}

// Tables this gate does not render entry by entry: the lambda and closure
// records, the interpolation desugars, and the three per-call-site
// argument tables. Their values are AST pointers or nested lists, and a
// renderer for each is work that belongs with the phase that makes one of
// them incremental. A size mismatch is still a hard failure - it catches
// an entry that leaked or vanished across an invalidation, just not one
// whose contents went stale in place.
fn diff_sizes(d: &ResultDiff, a: &TypeCheckResult, b: &TypeCheckResult, alloc: &Allocator?) {
    size_note(d, "lambdas", a.lambdas.len(), b.lambdas.len())
    size_note(d, "closures", a.closures.len(), b.closures.len())
    size_note(d, "desugars", a.desugars.len(), b.desugars.len())
    size_note(d, "default_args", a.default_args.len(), b.default_args.len())
    size_note(d, "arg_lists", a.arg_lists.len(), b.arg_lists.len())
    size_note(d, "receiver_derefs", a.receiver_derefs.len(), b.receiver_derefs.len())
}

fn size_note(d: &ResultDiff, name: String, al: usize, bl: usize) {
    if al == bl { return }
    note(d, $"{name}: {al} entries vs {bl}")
}

// ─────────────────────────────────────────────────────────────────────
// Renderings
//
// Every field a consumer can observe goes into the text; anything left
// out is a difference this gate cannot see.
// ─────────────────────────────────────────────────────────────────────

fn append_nominal(sb: &StringBuilder, def: &NominalDef, it: &TypeInterner) {
    def.* match {
        NomStruct(s) => {
            sb.append("struct ")
            sb.append(s.fqn)
            sb.append("@")
            sb.append(s.module)
            sb.append(" params=")
            sb.append(s.type_params.len)
            sb.append(" pub=")
            sb.append(s.is_pub)
            sb.append(" simd=")
            sb.append(s.is_simd)
            sb.append(" foreign=")
            sb.append(s.is_foreign)
            sb.append(" {")
            for i in 0..s.fields.len {
                if i > 0 { sb.append(",") }
                sb.append(s.fields[i].name)
                sb.append(":")
                it.format(s.fields[i].ty, sb)
            }
            sb.append("}")
        },
        NomEnum(e) => {
            sb.append("enum ")
            sb.append(e.fqn)
            sb.append("@")
            sb.append(e.module)
            sb.append(" params=")
            sb.append(e.type_params.len)
            sb.append(" pub=")
            sb.append(e.is_pub)
            sb.append(" {")
            for i in 0..e.variants.len {
                if i > 0 { sb.append(",") }
                sb.append(e.variants[i].name)
                sb.append("(")
                let payloads = &e.variants[i].payloads
                for k in 0..payloads.len {
                    if k > 0 { sb.append(",") }
                    it.format(payloads[k], sb)
                }
                sb.append(")")
            }
            sb.append("}")
        },
    }
}

fn append_scheme(sb: &StringBuilder, f: &FunctionScheme, it: &TypeInterner) {
    sb.append("fn#")
    sb.append(f.id)
    sb.append(" ")
    sb.append(f.name)
    sb.append("@")
    f.module match {
        Some(m) => sb.append(m),
        None => sb.append("-"),
    }
    sb.append(" pub=")
    sb.append(f.is_pub)
    sb.append(" foreign=")
    sb.append(f.is_foreign)
    sb.append(" req=")
    sb.append(f.required_params)
    sb.append(" variadic=")
    sb.append(f.has_variadic)
    sb.append(" forall{")
    sb.append(f.signature.quantified.len() as u64)
    sb.append("} ")
    it.format(f.signature.body, sb)
}

fn append_spec(sb: &StringBuilder, sp: &Specialization, it: &TypeInterner) {
    sb.append(sp.module)
    sb.append(".")
    sb.append(sp.name)
    sb.append(" fn#")
    sb.append(sp.function_id)
    sb.append(" key=")
    sb.append(sp.key.as_view())
    sb.append(" (")
    for i in 0..sp.concrete_params.len {
        if i > 0 { sb.append(",") }
        it.format(sp.concrete_params[i], sb)
    }
    sb.append(")->")
    it.format(sp.concrete_return, sb)
    sb.append(" overlay=")
    sb.append(sp.overlay.node_types.len())
}

fn append_target(sb: &StringBuilder, t: &ResolvedTarget) {
    t.* match {
        RtFunction(id) => { sb.append("fn#"); sb.append(id) },
        RtLocal(n) => { sb.append("local#"); sb.append(n) },
        RtStructField(nid, idx) => {
            sb.append("field#")
            sb.append(nid)
            sb.append(".")
            sb.append(idx)
        },
        RtEnumVariant(nid, idx) => {
            sb.append("variant#")
            sb.append(nid)
            sb.append(".")
            sb.append(idx)
        },
        RtSpecialized(id) => { sb.append("spec#"); sb.append(id) },
        RtConst(name) => { sb.append("const:"); sb.append(name) },
    }
}

fn append_op(sb: &StringBuilder, o: &ResolvedOperator) {
    sb.append("fn#")
    sb.append(o.function_id)
    sb.append(" neg=")
    sb.append(o.negate_result)
    sb.append(" ref=")
    sb.append(o.is_ref_form)
    sb.append(" cmp=")
    o.cmp_derived_op match {
        Some(dv) => sb.append(derived_name(dv)),
        None => sb.append("-"),
    }
    sb.append(" spec=")
    o.spec_id match {
        Some(s) => sb.append(s),
        None => sb.append("-"),
    }
}

fn derived_name(d: BinaryOpDerived) String {
    return d match {
        BodEq => "eq",
        BodNe => "ne",
        BodLt => "lt",
        BodLe => "le",
        BodGt => "gt",
        BodGe => "ge",
    }
}

// Tests

test "a result compares equal to itself" {
    let r = empty_result()
    defer r.deinit()
    let d = diff_results(&r, &r)
    defer d.deinit()
    assert_true(d.is_empty(), "an empty result has no differences with itself")
}

test "a renumbered nominal is a difference" {
    let a = empty_result()
    defer a.deinit()
    let b = empty_result()
    defer b.deinit()
    let areg = &a.nominals
    let breg = &b.nominals
    let _a0 = areg.register(NominalDef.NomStruct(diff_probe("m.A")), $"m.A")
    let b0 = breg.register(NominalDef.NomStruct(diff_probe("m.Other")), $"m.Other")
    let _b1 = breg.register(NominalDef.NomStruct(diff_probe("m.A")), $"m.A")

    let d = diff_results(&a, &b)
    defer d.deinit()
    assert_true(!d.is_empty(), "the same declaration under a different id is caught")
    assert_eq(b0, 0 as NominalId, "the right-hand registry did shift m.A to id 1")
}

test "an equal-sized table with one changed entry is caught" {
    let a = empty_result()
    defer a.deinit()
    let b = empty_result()
    defer b.deinit()
    let at = &a.node_types
    let bt = &b.node_types
    at.set(7 as NodeId, prim_of(PrimitiveKind.I32))
    bt.set(7 as NodeId, prim_of(PrimitiveKind.I64))

    let d = diff_results(&a, &b)
    defer d.deinit()
    assert_eq(d.total, 1 as usize, "one entry differs, one difference reported")
    assert_true(d.messages.len == 1 as usize, "and it is spelled out")
}

test "an entry present on only one side is caught" {
    let a = empty_result()
    defer a.deinit()
    let b = empty_result()
    defer b.deinit()
    let at = &a.node_types
    let bt = &b.node_types
    at.set(7 as NodeId, prim_of(PrimitiveKind.I32))
    bt.set(7 as NodeId, prim_of(PrimitiveKind.I32))
    bt.set(9 as NodeId, prim_of(PrimitiveKind.I32))

    let d = diff_results(&a, &b)
    defer d.deinit()
    assert_eq(d.total, 1 as usize, "the size mismatch alone reports the extra entry")
}

fn diff_probe(fqn: String) StructDef {
    let no_params: List(VarId) = list(0)
    let no_fields: List(Field) = list(0)
    return StructDef {
        fqn = fqn, module = "m", is_pub = true,
        type_params = no_params, fields = no_fields,
        decl_span = none_span(), deprecation = null,
        is_simd = false, is_foreign = false,
    }
}
