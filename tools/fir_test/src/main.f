// fir_test — exercises lib/flang_codegen by hand-building example FIR
// modules and printing them. Acts as a regression check against the
// canonical text format in `docs/fir.md` until colocated-test running
// is wired up.

import std.allocator
import std.list
import std.option
import std.string
import std.string_builder
import flang_codegen.fir
import flang_codegen.print
import flang_codegen.builder

pub fn main() i32 {
    let m = module()
    defer m.deinit()

    m.add_function(build_factorial())
    m.add_function(build_next())
    m.add_function(build_sum_range())

    let sb = string_builder(1024)
    defer sb.deinit()
    print(&m, &sb)

    print(sb.as_view())
    return 0
}

// fn factorial(n: i32) i32 { if n <= 1 { 1 } else { n * factorial(n - 1) } }
fn build_factorial() Function {
    let fb = function("factorial", IrType.I32)
    const n = fb.param(IrType.I32)
    let entry = fb.entry()
    let base = fb.block("base")
    let recur = fb.block("recur")

    const t0 = entry.icmp_sle(IrType.I32, n, int(1))
    entry.br_if(t0, "base", "recur")

    base.ret(int(1))

    const t1 = recur.isub(IrType.I32, n, int(1))
    const t2 = recur.call_one("factorial", IrType.I32, t1)
    const t3 = recur.imul(IrType.I32, n, t2)
    recur.ret(t3)

    return fb.finish()
}

// type RangeIter = struct { current: i32, end: i32 }   // size 8, align 4
// type Option(i32) = enum { Some(i32), None }          // {tag: i8, value: i32}, size 8
//
// fn iter(self: &RangeIter) RangeIter { return self.* }
// fn next(self: &RangeIter) Option(i32) {
//     if self.current >= self.end { return None }
//     let v = self.current
//     self.current = v + 1
//     return Some(v)
// }
//
// `iter` is the required entry point for `for v in it` — for types that
// are already iterators it just returns a copy of self. Inlined away by
// the time we get to FIR, so only `next` is built here.
//
// Aggregate return is lowered to a hidden out-pointer first parameter
// (`sret` convention). Both parameters are `ptr`.
fn build_next() Function {
    let void_ret: IrType? = null
    let fb = function("next", void_ret)
    const it = fb.param(IrType.Ptr)
    const ret = fb.param(IrType.Ptr)
    let entry = fb.entry()
    let exhausted = fb.block("exhausted")
    let advance = fb.block("advance")

    const cur_ptr = entry.gep(it, int(0))
    const cur = entry.load(IrType.I32, cur_ptr)
    const end_ptr = entry.gep(it, int(4))
    const end = entry.load(IrType.I32, end_ptr)
    const done = entry.icmp_sge(IrType.I32, cur, end)
    entry.br_if(done, "exhausted", "advance")

    const tag_ptr_n = exhausted.gep(ret, int(0))
    exhausted.store(IrType.I8, int(1), tag_ptr_n)
    exhausted.ret_void()

    const tag_ptr_s = advance.gep(ret, int(0))
    advance.store(IrType.I8, int(0), tag_ptr_s)
    const val_ptr = advance.gep(ret, int(4))
    advance.store(IrType.I32, cur, val_ptr)
    const next = advance.iadd(IrType.I32, cur, int(1))
    advance.store(IrType.I32, next, cur_ptr)
    advance.ret_void()

    return fb.finish()
}

// fn sum_range(start: i32, end: i32) i32 {
//     let it = RangeIter { current = start, end = end }
//     let acc = 0
//     for v in it {
//         acc = acc + v
//     }
//     return acc
// }
//
// `for v in it` desugars to a `loop` that calls `it.next()` each
// iteration and matches on the returned `Option`: `Some(v) => body`,
// `None => break`. That's the structure of the FIR below.
fn build_sum_range() Function {
    let fb = function("sum_range", IrType.I32)
    const start = fb.param(IrType.I32)
    const end_p = fb.param(IrType.I32)
    let entry = fb.entry()
    let loop_blk = fb.block("loop", IrType.I32)
    let pull = fb.block("pull")
    let done = fb.block("done")

    const it_ptr = entry.stack_slot(8u64, 4u64)
    const it_cur = entry.gep(it_ptr, int(0))
    entry.store(IrType.I32, start, it_cur)
    const it_end = entry.gep(it_ptr, int(4))
    entry.store(IrType.I32, end_p, it_end)

    const opt_ptr = entry.stack_slot(8u64, 4u64)

    let entry_args: List(Operand) = list(1)
    entry_args.push(int(0))
    entry.br_args("loop", entry_args)

    const acc = loop_blk.param(0)
    let call_args: List(Operand) = list(2)
    call_args.push(it_ptr)
    call_args.push(opt_ptr)
    loop_blk.call_void("next", call_args)
    const tag_ptr = loop_blk.gep(opt_ptr, int(0))
    const tag = loop_blk.load(IrType.I8, tag_ptr)
    const is_none = loop_blk.icmp_eq(IrType.I8, tag, int(1))
    loop_blk.br_if(is_none, "done", "pull")

    const val_ptr = pull.gep(opt_ptr, int(4))
    const val = pull.load(IrType.I32, val_ptr)
    const acc1 = pull.iadd(IrType.I32, acc, val)
    let back_args: List(Operand) = list(1)
    back_args.push(acc1)
    pull.br_args("loop", back_args)

    done.ret(acc)

    return fb.finish()
}
