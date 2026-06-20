// Phase 3 of the FIR optimization pipeline (RFC-015): inline small,
// non-recursive, single-block callees into their callers. The point
// isn't general perf — at -O2 the C compiler unwraps shim wrappers
// itself. The point is collapsing FLang's scoped-mutability mutator
// pattern (`pub fn add_function(self, f) { self.functions.push(f) }`)
// so:
//   1. Debug builds emit readable C.
//   2. Stack-local structs stop having their addresses escape into
//      opaque calls — making mem2reg's escape analysis tractable in
//      the later pipeline phases.
//
// Phase 3 handles single-block callees only. Multi-block (`Result`-
// style early-return) callees come in Phase 4. The inliner is meant
// to run on every build; it does not key off debug/release mode.
//
// TODO(rfc-015 §8 Q6): once we emit `#line` directives the splice
// needs to preserve the callee's source spans rather than reusing
// the call site's. Flag-only for now — there are no line directives
// to corrupt yet.

import std.allocator
import std.bitset
import std.dict
import std.list
import std.option
import std.set
import std.string
import flang_codegen.fir

// Empirical lower bound on the FLang corpus — matches the C# pre-
// decessor (`InliningPass.MaxInlineInstructions = 15`). Tune from
// `InlineStats.bail_size` data when it accumulates.
pub const MAX_INLINE_INSTRS: usize = 15

// Hard cap on the fixed-point loop. Each successful pass shrinks the
// inlinable set as leaves disappear, so this is just a safety net.
pub const MAX_PASSES: i32 = 10

// Telemetry returned to the caller. Bail counters are recorded on the
// first pass only — later passes operate on whatever the first pass
// didn't already absorb and double-counting would be misleading.
pub type InlineStats = struct {
    passes: i32
    inlined: usize
    bail_size: usize
    bail_multi_block: usize
    bail_recursive: usize
    bail_indirect: usize
    bail_non_ret: usize
}

// Run the inliner over `m` to fixed point. The module is mutated in
// place; functions that became uncalled by inlining stay in the
// module (dead-function elimination is a separate pass — RFC-015 §4).
pub fn inline_shims(m: &IrModule, allocator: &Allocator? = null) InlineStats {
    const alloc = allocator.or_global()
    let stats = InlineStats {
        passes = 0,
        inlined = 0,
        bail_size = 0,
        bail_multi_block = 0,
        bail_recursive = 0,
        bail_indirect = 0,
        bail_non_ret = 0,
    }

    for pass in 0..MAX_PASSES {
        let foreigns = collect_foreign_names(m, alloc)
        defer foreigns.deinit()
        let recursive = find_recursive(m, &foreigns, alloc)
        defer recursive.deinit()

        let inlinable_idx: Dict(OwnedString, usize) = dict(alloc)
        defer inlinable_idx.deinit()

        let any_eligible = false
        for i in 0..m.functions.len {
            const f = &m.functions[i]
            if f.name == "main" { continue }
            if recursive.contains(f.name) {
                if pass == 0 { stats.bail_recursive = stats.bail_recursive + 1 }
                continue
            }
            if f.blocks.len != 1 {
                if pass == 0 { stats.bail_multi_block = stats.bail_multi_block + 1 }
                continue
            }
            const body_len = f.blocks[0].instrs.len
            if body_len > MAX_INLINE_INSTRS {
                if pass == 0 { stats.bail_size = stats.bail_size + 1 }
                continue
            }
            if !is_ret_terminator(&f.blocks[0].terminator) {
                if pass == 0 { stats.bail_non_ret = stats.bail_non_ret + 1 }
                continue
            }
            if contains_indirect_or_foreign(&f.blocks[0].instrs, &foreigns) {
                if pass == 0 { stats.bail_indirect = stats.bail_indirect + 1 }
                continue
            }
            inlinable_idx.set(f.name, i)
            any_eligible = true
        }
        stats.passes = pass + 1
        if !any_eligible { break }

        let any_inlined = false
        for j in 0..m.functions.len {
            if m.functions[j].name == "main" { continue }
            const did = inline_calls_in(m, j, &inlinable_idx, alloc)
            if did > 0 {
                any_inlined = true
                stats.inlined = stats.inlined + did
            }
        }
        if !any_inlined { break }
    }
    return stats
}

// ─────────────────────────────────────────────────────────────────────
// Eligibility helpers
// ─────────────────────────────────────────────────────────────────────

fn is_ret_terminator(t: &Terminator) bool {
    return t.* match {
        Ret(_) => true,
        _ => false,
    }
}

fn contains_indirect_or_foreign(instrs: &List(Instr), foreigns: &Set(OwnedString)) bool {
    for i in 0..instrs.len {
        instrs[i] match {
            Call(c) => {
                if foreigns.contains(c.callee) { return true }
            },
            CallIndirect(_) => return true,
            _ => {},
        }
    }
    return false
}

fn collect_foreign_names(m: &IrModule, alloc: &Allocator) Set(OwnedString) {
    let s: Set(OwnedString) = set(alloc)
    for i in 0..m.foreigns.len {
        s.add(m.foreigns[i].name)
    }
    return s
}

// ─────────────────────────────────────────────────────────────────────
// Call-graph reachability — a function is recursive iff its own direct
// callees can reach it transitively. Covers self-loops and mutual
// recursion (A → B → A) uniformly without a stack-based SCC pass.
// O(V * (V + E)) on the call graph; V is hundreds even on big modules.
// ─────────────────────────────────────────────────────────────────────

fn find_recursive(m: &IrModule, foreigns: &Set(OwnedString), alloc: &Allocator) Set(OwnedString) {
    let name_to_idx: Dict(OwnedString, usize) = dict(alloc)
    defer name_to_idx.deinit()
    for i in 0..m.functions.len {
        name_to_idx.set(m.functions[i].name, i)
    }

    let adj: List(List(usize)) = list(m.functions.len, alloc)
    defer {
        for i in 0..adj.len {
            let e = &adj[i]
            e.deinit()
        }
        adj.deinit()
    }
    for i in 0..m.functions.len {
        let edges: List(usize) = list(0, alloc)
        const f = &m.functions[i]
        for bi in 0..f.blocks.len {
            const b = &f.blocks[bi]
            for ii in 0..b.instrs.len {
                b.instrs[ii] match {
                    Call(c) => {
                        if foreigns.contains(c.callee) { continue }
                        const idx_opt = name_to_idx.get(c.callee)
                        idx_opt match {
                            Some(idx) => edges.push(idx),
                            None => {},
                        }
                    },
                    _ => {},
                }
            }
        }
        adj.push(edges)
    }

    let recursive: Set(OwnedString) = set(alloc)
    for i in 0..m.functions.len {
        if reaches_self(&adj, i, alloc) {
            recursive.add(m.functions[i].name)
        }
    }
    return recursive
}

fn reaches_self(adj: &List(List(usize)), start: usize, alloc: &Allocator) bool {
    // Dense integer membership — Bitset is one bit per element vs
    // Set(usize)'s ~32 bytes/entry hash table. set.f's preamble
    // explicitly points at Bitset for this case.
    let visited = bitset(adj.len, alloc)
    defer visited.deinit()
    let queue: List(usize) = list(0, alloc)
    defer queue.deinit()

    const seeds = &adj[start]
    for i in 0..seeds.len {
        const c = seeds[i]
        if !visited.contains(c) {
            visited.add(c)
            queue.push(c)
        }
    }

    let head: usize = 0
    while head < queue.len {
        const n = queue[head]
        head = head + 1
        if n == start { return true }
        const children = &adj[n]
        for i in 0..children.len {
            const c = children[i]
            if !visited.contains(c) {
                visited.add(c)
                queue.push(c)
            }
        }
    }
    return false
}

// ─────────────────────────────────────────────────────────────────────
// Per-caller pass — rebuild every block with inlinable calls spliced
// in place. Uses two substitution maps:
//
//   result_subst : Dict(u32, Operand)
//     Function-scoped. Maps the SSA id of an already-inlined call's
//     original result to the operand that replaces it (the callee's
//     return value, in caller terms). Used to rewrite operands of
//     every subsequent instruction and terminator.
//
//   local_subst  : Dict(u32, Operand)   (built per splice; see splice_callee)
//     Splice-scoped. Maps every SSA id used inside the callee body
//     (params → caller args; instruction results → caller-fresh ids)
//     to the operand to substitute in the cloned instruction.
// ─────────────────────────────────────────────────────────────────────

fn inline_calls_in(m: &IrModule, caller_idx: usize, inlinable: &Dict(OwnedString, usize), alloc: &Allocator) usize {
    let inlined_count: usize = 0
    let result_subst: Dict(u32, Operand) = dict(alloc)
    defer result_subst.deinit()

    // Chained access (m.functions[i].blocks[j].something = …) writes to
    // a temp copy in flang's lowering today — bind the caller once and
    // use that ref for all reads/writes inside the loop.
    let caller = &m.functions[caller_idx]
    const block_count = caller.blocks.len
    for bi in 0..block_count {
        let block_ref = &caller.blocks[bi]
        let new_instrs: List(Instr) = list(block_ref.instrs.len, alloc)
        const old_len = block_ref.instrs.len

        for ii in 0..old_len {
            const inst_ref = &block_ref.instrs[ii]
            inst_ref.* match {
                Call(c) => {
                    let do_splice = false
                    let callee_idx: usize = 0
                    const idx_opt = inlinable.get(c.callee)
                    idx_opt match {
                        Some(idx) => {
                            // SCC analysis already excludes self-recursion,
                            // but the guard is cheap and protects against any
                            // future caller that bypasses eligibility.
                            if idx != caller_idx {
                                do_splice = true
                                callee_idx = idx
                            }
                        },
                        None => {},
                    }

                    if do_splice {
                        // Re-route the call's args through any prior splice's
                        // result substitutions before binding to callee params.
                        let effective_args: List(Operand) = list(c.args.len, alloc)
                        defer effective_args.deinit()
                        for ai in 0..c.args.len {
                            effective_args.push(remap_operand(c.args[ai], &result_subst))
                        }

                        const ret_op = splice_callee(
                            m, callee_idx, caller, &effective_args, &new_instrs, alloc,
                        )

                        c.result match {
                            Some(old_id) => {
                                ret_op match {
                                    Some(rop) => result_subst.set(old_id, rop),
                                    None => {},
                                }
                            },
                            None => {},
                        }
                        inlined_count = inlined_count + 1
                    } else {
                        new_instrs.push(rewrite_instr(inst_ref, &result_subst, alloc))
                    }
                },
                _ => new_instrs.push(rewrite_instr(inst_ref, &result_subst, alloc)),
            }
        }

        const new_term = rewrite_terminator(&block_ref.terminator, &result_subst, alloc)
        // Swap in the freshly-built lists; deinit the previous storage.
        // Direct field assignment is blocked by scoped mutability (Block
        // is defined in fir), so we route through `replace_*` helpers.
        let old_instrs = block_ref.replace_instrs(new_instrs)
        old_instrs.deinit()
        let old_term = block_ref.replace_terminator(new_term)
        old_term.deinit()
    }
    return inlined_count
}

// Splice a single inlinable call. Reads from `m.functions[callee_idx]`,
// allocates fresh SSA ids on `caller`, appends the cloned instructions
// to `out`, and returns the operand replacing the call's result (or
// `None` for void).
fn splice_callee(
    m: &IrModule,
    callee_idx: usize,
    caller: &Function,
    args: &List(Operand),
    out: &List(Instr),
    alloc: &Allocator,
) Operand? {
    let local_subst: Dict(u32, Operand) = dict(alloc)
    defer local_subst.deinit()

    let callee = &m.functions[callee_idx]
    const callee_param_count = callee.params.len
    for i in 0..callee_param_count {
        if i >= args.len { break }
        const pid = callee.params[i].id
        local_subst.set(pid, args[i])
    }

    const cb = &callee.blocks[0]
    const instr_count = cb.instrs.len
    for i in 0..instr_count {
        const src_ref = &cb.instrs[i]
        const cloned = clone_callee_instr(src_ref, &local_subst, caller, alloc)
        out.push(cloned)
    }

    let result: Operand? = null
    cb.terminator match {
        Ret(v) => {
            v match {
                Some(op) => result = remap_operand(op, &local_subst),
                None => {},
            }
        },
        _ => {},
    }
    return result
}

// ─────────────────────────────────────────────────────────────────────
// Operand / instruction / terminator cloning. Each instruction variant
// has two cloning paths:
//
//   clone_callee_instr — used while splicing a callee body. Mints a
//     fresh result id via `caller.fresh_value_id()` for every value-
//     producing instruction and records `old_id → Local(new_id)` in
//     the splice-local substitution map. Operands are remapped first
//     (SSA forbids forward-references to one's own result).
//
//   rewrite_instr — used for caller instructions that aren't being
//     inlined. Preserves result ids; only remaps operands through the
//     function-scoped result substitution.
//
// Both paths always allocate fresh inner lists (call args, variadic
// type lists, branch-target args). The old block's instruction list
// gets deinit'd wholesale after the rewrite, so reusing list buffers
// across new/old would dangle.
// ─────────────────────────────────────────────────────────────────────

fn remap_operand(op: Operand, subst: &Dict(u32, Operand)) Operand {
    return op match {
        Local(id) => {
            const found = subst.get(id)
            found match {
                Some(o) => o,
                None => op,
            }
        },
        _ => op,
    }
}

fn clone_operand_list(args: &List(Operand), subst: &Dict(u32, Operand), alloc: &Allocator) List(Operand) {
    let out: List(Operand) = list(args.len, alloc)
    for i in 0..args.len {
        out.push(remap_operand(args[i], subst))
    }
    return out
}

fn clone_ir_type_list(tys: &List(IrType), alloc: &Allocator) List(IrType) {
    let out: List(IrType) = list(tys.len, alloc)
    for i in 0..tys.len {
        out.push(tys[i])
    }
    return out
}

fn clone_block_target(t: &BlockTarget, subst: &Dict(u32, Operand), alloc: &Allocator) BlockTarget {
    return BlockTarget {
        label = t.label,
        args = clone_operand_list(&t.args, subst, alloc),
    }
}

fn clone_callee_instr(
    inst: &Instr,
    subst: &Dict(u32, Operand),
    caller: &Function,
    alloc: &Allocator,
) Instr {
    return inst.* match {
        Binary(b) => {
            const lhs = remap_operand(b.lhs, subst)
            const rhs = remap_operand(b.rhs, subst)
            const new_id = caller.fresh_value_id()
            subst.set(b.result, Operand.Local(new_id))
            Instr.Binary(BinaryInstr {
                result = new_id, op = b.op, ty = b.ty, lhs = lhs, rhs = rhs,
            })
        },
        Unary(u) => {
            const operand = remap_operand(u.operand, subst)
            const new_id = caller.fresh_value_id()
            subst.set(u.result, Operand.Local(new_id))
            Instr.Unary(UnaryInstr {
                result = new_id, op = u.op, ty = u.ty, operand = operand,
            })
        },
        Compare(c) => {
            const lhs = remap_operand(c.lhs, subst)
            const rhs = remap_operand(c.rhs, subst)
            const new_id = caller.fresh_value_id()
            subst.set(c.result, Operand.Local(new_id))
            Instr.Compare(CompareInstr {
                result = new_id, op = c.op, operand_ty = c.operand_ty,
                lhs = lhs, rhs = rhs,
            })
        },
        Convert(c) => {
            const operand = remap_operand(c.operand, subst)
            const new_id = caller.fresh_value_id()
            subst.set(c.result, Operand.Local(new_id))
            Instr.Convert(ConvertInstr {
                result = new_id, op = c.op,
                source_ty = c.source_ty, result_ty = c.result_ty,
                operand = operand,
            })
        },
        StackSlot(s) => {
            const new_id = caller.fresh_value_id()
            subst.set(s.result, Operand.Local(new_id))
            Instr.StackSlot(StackSlotInstr {
                result = new_id, size = s.size, align = s.align,
            })
        },
        Load(l) => {
            const ptr = remap_operand(l.ptr, subst)
            const new_id = caller.fresh_value_id()
            subst.set(l.result, Operand.Local(new_id))
            Instr.Load(LoadInstr {
                result = new_id, ty = l.ty, ptr = ptr, align = l.align,
            })
        },
        Store(s) => {
            const value = remap_operand(s.value, subst)
            const ptr = remap_operand(s.ptr, subst)
            Instr.Store(StoreInstr {
                ty = s.ty, value = value, ptr = ptr, align = s.align,
            })
        },
        Gep(g) => {
            const ptr = remap_operand(g.ptr, subst)
            const offset = remap_operand(g.offset, subst)
            const new_id = caller.fresh_value_id()
            subst.set(g.result, Operand.Local(new_id))
            Instr.Gep(GepInstr {
                result = new_id, ptr = ptr, offset = offset,
            })
        },
        Memcpy(mc) => {
            const dst = remap_operand(mc.dst, subst)
            const src = remap_operand(mc.src, subst)
            const size = remap_operand(mc.size, subst)
            Instr.Memcpy(MemcpyInstr {
                dst = dst, src = src, size = size,
            })
        },
        Memset(ms) => {
            const dst = remap_operand(ms.dst, subst)
            const byte = remap_operand(ms.byte, subst)
            const size = remap_operand(ms.size, subst)
            Instr.Memset(MemsetInstr {
                dst = dst, byte = byte, size = size,
            })
        },
        Call(c) => {
            const args = clone_operand_list(&c.args, subst, alloc)
            const var_types = clone_ir_type_list(&c.variadic_arg_types, alloc)
            let new_result: u32? = null
            let new_result_ty: IrType? = null
            c.result match {
                Some(old_id) => {
                    const fresh_id = caller.fresh_value_id()
                    new_result = fresh_id
                    subst.set(old_id, Operand.Local(fresh_id))
                    c.result_ty match {
                        Some(ty) => new_result_ty = ty,
                        None => {},
                    }
                },
                None => {},
            }
            Instr.Call(CallInstr {
                result = new_result,
                result_ty = new_result_ty,
                callee = c.callee,
                args = args,
                variadic_arg_types = var_types,
            })
        },
        CallIndirect(c) => {
            const fn_ptr = remap_operand(c.fn_ptr, subst)
            const args = clone_operand_list(&c.args, subst, alloc)
            const var_types = clone_ir_type_list(&c.variadic_arg_types, alloc)
            const param_types = clone_ir_type_list(&c.param_types, alloc)
            let new_result: u32? = null
            let new_result_ty: IrType? = null
            c.result match {
                Some(old_id) => {
                    const fresh_id = caller.fresh_value_id()
                    new_result = fresh_id
                    subst.set(old_id, Operand.Local(fresh_id))
                    c.result_ty match {
                        Some(ty) => new_result_ty = ty,
                        None => {},
                    }
                },
                None => {},
            }
            Instr.CallIndirect(CallIndirectInstr {
                result = new_result,
                result_ty = new_result_ty,
                fn_ptr = fn_ptr,
                param_types = param_types,
                args = args,
                variadic_arg_types = var_types,
                cc = c.cc,
            })
        },
    }
}

fn rewrite_instr(inst: &Instr, subst: &Dict(u32, Operand), alloc: &Allocator) Instr {
    return inst.* match {
        Binary(b) => Instr.Binary(BinaryInstr {
            result = b.result, op = b.op, ty = b.ty,
            lhs = remap_operand(b.lhs, subst),
            rhs = remap_operand(b.rhs, subst),
        }),
        Unary(u) => Instr.Unary(UnaryInstr {
            result = u.result, op = u.op, ty = u.ty,
            operand = remap_operand(u.operand, subst),
        }),
        Compare(c) => Instr.Compare(CompareInstr {
            result = c.result, op = c.op, operand_ty = c.operand_ty,
            lhs = remap_operand(c.lhs, subst),
            rhs = remap_operand(c.rhs, subst),
        }),
        Convert(c) => Instr.Convert(ConvertInstr {
            result = c.result, op = c.op,
            source_ty = c.source_ty, result_ty = c.result_ty,
            operand = remap_operand(c.operand, subst),
        }),
        StackSlot(s) => Instr.StackSlot(StackSlotInstr {
            result = s.result, size = s.size, align = s.align,
        }),
        Load(l) => Instr.Load(LoadInstr {
            result = l.result, ty = l.ty,
            ptr = remap_operand(l.ptr, subst), align = l.align,
        }),
        Store(s) => Instr.Store(StoreInstr {
            ty = s.ty,
            value = remap_operand(s.value, subst),
            ptr = remap_operand(s.ptr, subst),
            align = s.align,
        }),
        Gep(g) => Instr.Gep(GepInstr {
            result = g.result,
            ptr = remap_operand(g.ptr, subst),
            offset = remap_operand(g.offset, subst),
        }),
        Memcpy(mc) => Instr.Memcpy(MemcpyInstr {
            dst = remap_operand(mc.dst, subst),
            src = remap_operand(mc.src, subst),
            size = remap_operand(mc.size, subst),
        }),
        Memset(ms) => Instr.Memset(MemsetInstr {
            dst = remap_operand(ms.dst, subst),
            byte = remap_operand(ms.byte, subst),
            size = remap_operand(ms.size, subst),
        }),
        Call(c) => Instr.Call(CallInstr {
            result = c.result, result_ty = c.result_ty,
            callee = c.callee,
            args = clone_operand_list(&c.args, subst, alloc),
            variadic_arg_types = clone_ir_type_list(&c.variadic_arg_types, alloc),
        }),
        CallIndirect(c) => Instr.CallIndirect(CallIndirectInstr {
            result = c.result, result_ty = c.result_ty,
            fn_ptr = remap_operand(c.fn_ptr, subst),
            param_types = clone_ir_type_list(&c.param_types, alloc),
            args = clone_operand_list(&c.args, subst, alloc),
            variadic_arg_types = clone_ir_type_list(&c.variadic_arg_types, alloc),
            cc = c.cc,
        }),
    }
}

fn rewrite_terminator(t: &Terminator, subst: &Dict(u32, Operand), alloc: &Allocator) Terminator {
    return t.* match {
        Br(target) => Terminator.Br(clone_block_target(&target, subst, alloc)),
        BrIf(b) => Terminator.BrIf(BrIfTerm {
            cond = remap_operand(b.cond, subst),
            then_target = clone_block_target(&b.then_target, subst, alloc),
            else_target = clone_block_target(&b.else_target, subst, alloc),
        }),
        Ret(v) => {
            let new_v: Operand? = null
            v match {
                Some(op) => new_v = remap_operand(op, subst),
                None => {},
            }
            Terminator.Ret(new_v)
        },
        Unreachable => Terminator.Unreachable,
    }
}
