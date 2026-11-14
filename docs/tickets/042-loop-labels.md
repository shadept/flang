---
type: language
created: 2026-11-10
linear: SH-55
implemented: 2026-11-13
relates: [RFC-005, RFC-015]
---

# RFC-042: Loop labels

## Summary

A loop can carry a label, and `break` and `continue` can name the loop they act on:

```flang
outer: for row in rows {
    for cell in row {
        if cell.bad { continue outer }
        if cell.done { break outer }
    }
}
```

That is the whole feature. Labels carry no values, and loops stay statements. State machines
need nothing more: they are written with `loop`, `match` and a labeled `continue` (§4).

## Motivation

**Flags that exist only to leave an outer loop.** A bare `break` leaves the innermost loop, so
code that needs to leave or restart an outer one sets a flag, breaks, and tests the flag after.
From `stdlib/std/string.f` (reverse substring search):

```flang
while i != 0 {
    i = i - 1
    let found = true
    for j in 0..n.len {
        if h[i + j] != n[j] {
            found = false
            break
        }
    }
    if found { return Some(i) }
}
```

With a label the flag goes away:

```flang
outer: while i != 0 {
    i = i - 1
    for j in 0..n.len {
        if h[i + j] != n[j] { continue outer }
    }
    return Some(i)
}
```

The same shape appears in `stdlib/std/string_builder.f`, `stdlib/std/readline.f` and
`stdlib/std/test.f`.

**State machines.** A state machine that runs several transitions in one go is a loop around a
`match` on the current state. Inside an arm, a nested loop or match makes a bare `continue` or
`break` ambiguous to the reader and wrong for the compiler as soon as the arm contains a loop of
its own. Naming the machine's loop fixes both (§4).

## 1. Syntax

```
labeled_loop := IDENT ':' (for_loop | while_loop | loop_loop)
break_stmt   := 'break' IDENT?
continue_stmt:= 'continue' IDENT?
```

- The label goes in front of `for`, `while` or `loop`, on the same line. A statement never starts
  with `IDENT ':'` today (annotations follow `let` or `const`; named arguments and struct fields
  use `=`), so the form is unambiguous.
- After `break` or `continue`, an identifier **on the same line** is a label. A newline ends the
  statement as it does today, so `break` followed by `foo()` on the next line is a bare `break`.
- Labels work wherever `break` and `continue` already do, including a `??` right side and a match
  arm body: `let job = queue.pop() ?? break outer`.

## 2. Semantics

1. **Resolution.** A label names the nearest enclosing loop that carries it. Labels live in their
   own namespace: a label and a variable may share a name.
2. **`break l`** jumps to the first statement after loop `l`. **`continue l`** starts the next
   iteration of `l`: for `while` the condition is evaluated again, for `for` the iterator is
   advanced, for `loop` the body runs again.
3. **Exits run cleanup innermost first.** Every scope the jump leaves fires its defers, and every
   `for` it leaves releases what it iterates with (spec §7.4, "the loop owns what it iterates
   with"), in the order those scopes close. `continue l` releases the iterators of the loops
   nested inside `l`, not `l`'s own.
4. **Lambdas.** A lambda body is outside every enclosing loop (as for bare `break` today, E1006
   and E1007), so it cannot see labels outside itself. A label inside a lambda may reuse a name
   used outside it.
5. **`context(...) { }`** is a block, not a boundary: a labeled jump passes through it as
   `return` does (spec §4.4), restoring the outer context on the way out.
6. **No values.** `break` and `continue` take no value. `break l v` is a syntax error.

## 3. Diagnostics

| Case | Code |
|---|---|
| `break l` / `continue l` where no enclosing loop is labeled `l` | E1055 |
| A label that reuses the name of an enclosing loop's label | E1056 |
| A label that no `break` or `continue` names | W1005 |
| A label in front of anything but `for`, `while` or `loop` | E1057 |
| A value after `break` or `continue` | E1002 |

The "unknown label" message lists the labels in scope, nearest first.

## 4. State machines

No dedicated construct. A state machine is a state variable, a labeled `loop`, and a `match`:

```flang
type State = enum { Gap, Word(usize) }

let state = State.Gap
let i: usize = 0

scan: loop {
    state match {
        Gap => {
            if i == src.len { break scan }
            let c = src[i]
            i += 1
            if is_alpha(c) { state = Word(i - 1) }
            continue scan
        }
        Word(start) => {
            if i == src.len or src[i] == b' ' {
                emit(src[start..i])
                state = Gap
                continue scan
            }
            i += 1
        }
    }
}
```

- **It reads top to bottom.** The head reads `state`, a variable whose assignments are visible at
  each transition, so tracing a path by hand never hits a stale value.
- **Progress lives in the arms.** The `match` itself does nothing; each arm advances `i`, emits,
  or changes `state`. As with any `loop`, termination is the author's job.
- **Data that belongs to one state** goes in that variant's payload (`Word(start)`).
- **A machine that waits between steps** (one loaded from a database, or anything driven by
  events) is a function: load the state, run until it must wait, store the new state, return. A
  single transition needs no loop at all; the labeled loop appears when one event passes through
  several states without waiting.
- **Speed.** `state = X; continue scan` stores `X`, jumps to the head and tests the tag again.
  When `X` is known at that point, an optimizer can jump straight to the arm instead; clang does
  this at `-O2`, and RFC-015 tracks doing it in FIR. No syntax is needed for it.

## 5. Considered and not included

**Loops with a value (`break l v`, loops as expressions, labeled blocks).** Surveyed across
`compiler/`, `lib/`, `stdlib/` and `tools/` (line-based, so approximate):

| | count |
|---|---|
| loops (`for` 1587, `while` 320, `loop` 103) | 2010 |
| `break` statements | 186 |
| `let x = ...` before a loop, `x = v; break` inside it | 25 |
| ...of which boolean flags | 13 |
| a loop that returns from inside, then a fallback `return` ending the function | 299 |

Search-with-a-value is common, but the codebase writes it almost entirely as a function that
returns early, which already is an expression with no new syntax. A value on `break` would change
about 20 sites from `let x` plus an assignment to `const x = ... break l v`. Against that: a new
typing rule, loops that usually produce nothing becoming expressions, and loops in argument
position. `for` and `while` can end without a `break`, so they could never take a value without
an `else` clause on top. Not justified now; adding it later breaks nothing.

**A labeled `match` with `continue l v`** (re-run the match with `v` as the subject, as Zig's
labeled `switch` does). The head shows the initial state and never changes, so reading the code
by hand goes back to a value that is no longer true. It also makes `match` a loop in disguise,
which every pass that treats loops specially (the ownership pass, defers, the formatter, the LSP)
would have to learn.

**A dedicated `machine { }` construct with a jump-to-arm keyword** (`goto`, `become`). Reads like
a state diagram, but needs new keywords and a new construct for what §4 already expresses.

## 6. Implementation

- **Parser** (`lib/flang_parser/src/parser.f`): `loop_depth` becomes a stack of optional labels.
  E1006 / E1007 keep their meaning for a bare jump outside every loop; a named jump resolves
  against the stack, and `leave_lambda` saves and resets it as it does the depth today.
- **CST / AST** (`cst.f`, `ast.f`, `projector.f`): `ForStmt`, `WhileStmt` and `LoopStmt` gain
  `label: Ident?`; `BreakStmt` and `ContinueStmt` gain `label: Ident?`. Drop the "FLang has no
  loop labels" comment on `BreakStmt`.
- **Ownership pass** (`lib/flang_typer/src/checker.f`, `own_loop` / `own_escape`): today one
  `escaped` / `continued` pair and one `loop_scope` belong to the innermost loop and are saved and
  restored around each loop. They become a stack of frames, and a labeled jump merges its moved
  set into the named frame and fires defers down to that frame's scope.
- **Lowering** (`lib/flang_driver/src/lower.f`): `LoopFrame` gains the label. A labeled jump
  searches `ctx.loops` from the top, fires defers past that frame's `defer_depth`, releases the
  iterators of the loops it leaves, and branches to that frame's `exit` or `latch`.
- **Formatter** keeps `name:` on the loop's line, followed by one space.
- **LSP**: go to definition and find references on a label; rename.
- **Seed rule**: `compiler/`, `lib/*` and `stdlib/` may use labels only after a promote. The flag
  sites listed in Motivation are the first candidates.
- **Harness tests** (`tests/harness/control_flow/`): break and continue an outer `for`, `while` and
  `loop`; defers firing in order across two levels; iterator release on `break outer` and
  `continue outer`; a jump through `context(...) { }`; `?? break outer`; each diagnostic in §3;
  a label inside a lambda reusing an outer name.
- **Docs on landing**: spec (control flow and §7.4), `docs/syntax.md` control flow,
  `docs/error-codes.md`.
