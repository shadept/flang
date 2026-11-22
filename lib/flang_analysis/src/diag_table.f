// The diagnostics a project stands on across re-checks: the last output of each carried pass over
// each module, plus what the last run regenerated whole. A re-check emits only the passes it ran,
// so a caller that re-checks merges each run in here.

import std.collections.dict
import std.collections.list
import std.collections.set
import std.result
import std.string
import std.test

import flang_core.diagnostic
import flang_core.span

import flang_analysis.analyze
import flang_analysis.project
import flang_analysis.resolver

pub type DiagTable = struct {
    // Indexed by `file_id * PASSES + pass`.
    slots: List(List(Diagnostic))
    // What the last run reported outside every slot.
    live: List(Diagnostic)
}

const PASSES: usize = 4

pub fn diag_table() DiagTable {
    return .{ slots = list(0), live = list(0) }
}

// A table holding the run `unit` just finished, as `record` leaves it.
pub fn diag_table_of(unit: &AnalyzedProject) DiagTable {
    let t = diag_table()
    t.record(unit)
    return t
}

pub fn deinit(self: move DiagTable) {
    self.slots.deinit()
    self.live.deinit()
}

// Merge the run `unit` just finished, leaving its output empty: each slot it reported replaces that
// slot's last output, and its unslotted diagnostics replace the last run's.
pub fn record(self: &DiagTable, unit: &AnalyzedProject) {
    self.merge(&unit.diagnostics, &unit.diag_slots)
}

fn merge(self: &DiagTable, diags: &List(Diagnostic), slots: &List(DiagSlot)) {
    for &s in slots {
        const at = slot_index(s)
        while self.slots.len <= at {
            self.slots.push(list(0))
        }
        self.slots[at].clear()
    }
    self.live.clear()
    let next = 0usize
    let k = 0usize
    for d in diags.drain() {
        while next < slots.len and k >= slots[next].end {
            next = next + 1
        }
        if next < slots.len and k >= slots[next].start {
            self.slots[slot_index(&slots[next])].push(d)
        } else {
            self.live.push(d)
        }
        k = k + 1
    }
    slots.clear()
}

fn slot_index(s: &DiagSlot) usize {
    const pass = s.pass match {
        Collect => 0usize
        Resolve => 1usize
        Signatures => 2usize
        Bodies => 3usize
    }
    return (s.file_id as usize) * PASSES + pass
}

// Every diagnostic the project stands on, lent: the carried passes' by module, then the last run's
// unslotted ones.
pub fn all(self: &DiagTable) List(&Diagnostic) {
    let out: List(&Diagnostic) = list(0)
    for &row in self.slots {
        for &d in row {
            out.push(d)
        }
    }
    for &d in self.live {
        out.push(d)
    }
    return out
}

// Every diagnostic, handed over; the table is left empty.
pub fn take(self: &DiagTable) List(Diagnostic) {
    let out: List(Diagnostic) = list(0)
    for &row in self.slots {
        for d in row.drain() {
            out.push(d)
        }
    }
    for d in self.live.drain() {
        out.push(d)
    }
    return out
}

pub fn error_count(self: &DiagTable) usize {
    let n = 0usize
    let lent = self.all()
    defer lent.deinit()
    for d in lent {
        if d.severity == Severity.Error {
            n = n + 1
        }
    }
    return n
}

fn diag_at(code: String, start: usize) Diagnostic {
    let empty: OwnedString
    return error(code, empty, SourceSpan { file_id = 0, start = start, length = 1 })
}

fn codes(t: &DiagTable) List(String) {
    let out: List(String) = list(0)
    let lent = t.all()
    defer lent.deinit()
    for d in lent {
        out.push(d.code)
    }
    return out
}

test "a run replaces the slots it reports and keeps the ones it carried" {
    let t = diag_table()
    defer t.deinit()

    // Run 1: module 0's resolve pass reports E1, its bodies E2, and E3 is unslotted.
    let d1: List(Diagnostic) = list(0)
    defer d1.deinit()
    d1.push(diag_at("E1", 0))
    d1.push(diag_at("E2", 1))
    d1.push(diag_at("E3", 2))
    let s1: List(DiagSlot) = list(0)
    defer s1.deinit()
    s1.push(DiagSlot { file_id = 0, pass = DiagPass.Resolve, start = 0, end = 1 })
    s1.push(DiagSlot { file_id = 0, pass = DiagPass.Bodies, start = 1, end = 2 })
    t.merge(&d1, &s1)
    assert_eq(d1.len, 0 as usize, "the run's output moves into the table")
    assert_eq(t.error_count(), 3 as usize, "everything the first run reported")

    // Run 2 carries resolve, re-runs bodies clean, and reports E4 unslotted.
    let d2: List(Diagnostic) = list(0)
    defer d2.deinit()
    d2.push(diag_at("E4", 3))
    let s2: List(DiagSlot) = list(0)
    defer s2.deinit()
    s2.push(DiagSlot { file_id = 0, pass = DiagPass.Bodies, start = 0, end = 0 })
    t.merge(&d2, &s2)
    let c = codes(&t)
    defer c.deinit()
    assert_eq(c.len, 2 as usize, "the carried slot and the new unslotted one")
    assert_true(c[0] == "E1", "the carried resolve output stands")
    assert_true(c[1] == "E4", "the unslotted output is the last run's")
}

test "a re-check that carries a pass keeps what it reported" {
    // One warning stays one warning across a re-demand of the same sources, whether the re-demand
    // re-runs the pass that reported it or carries it. An empty stdlib root leaves `core.prelude`
    // unresolved and `seed_stdlib` a no-op, so the module set is exactly what the override
    // supplies.
    let proj = parse_project(
        "[project]\nname = \"p\"\nkind = \"exe\"\nsource = \"src/**/*.f\"\n",
    ).unwrap()
    defer proj.deinit()
    let ctx = resolve_ctx(&proj, "")
    defer ctx.deinit()
    let entries: List(OwnedString) = list(1)
    defer entries.deinit()
    entries.push(from_view("src/main.f"))
    let ov: Dict(String, String) = dict()
    defer ov.deinit()
    ov.set(
        "src/main.f",
        "fn main() i32 {\n    const v: i32 = 1\n    const v: i32 = 2\n    return v\n}\n",
    )

    let unit = analyze_project(&ctx, &entries, Some(&ov))
    defer unit.deinit()
    assert_true(unit.checked, "the module type-checks")
    let t = diag_table()
    defer t.deinit()
    t.record(&unit)
    let cold = t.all()
    defer cold.deinit()
    assert_eq(cold.len, 1 as usize, "one shadowing warning")

    let dirty: Set(String) = set()
    defer dirty.deinit()
    reanalyze(&unit, &ctx, &dirty, Some(&ov))
    assert_eq(unit.diagnostics.len, 0 as usize, "the re-demand carries the pass that warned")
    t.record(&unit)
    let again = t.all()
    defer again.deinit()
    assert_eq(again.len, 1 as usize, "the same one warning, not two and not none")
}
