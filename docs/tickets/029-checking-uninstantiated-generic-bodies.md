---
status: deferred
type: compiler
created: 2026-09-01
relates: [RFC-022, RFC-023]
---

# RFC-029: Checking uninstantiated generic bodies

## Summary

A generic function's body is only ever checked at an instantiation
(`check_one_decl`, `lib/flang_typer/src/checker.f`). A template nothing calls is
never checked at all, so it can be arbitrarily broken and every suite stays
green:

```flang
pub fn ok(self: Result($T, $E)) T? {
    return self match {
        Ok(move v) => Some(move v)      // not a pattern - E2115, invisible
        Err(_) => None
    }
}
```

`std.result.ok` has no caller in tree, so this compiles, ships, and fails the
first time anyone writes `r.ok()`. `count_check_errors` pins the silence today
(`checker.f`, "generic template bodies only report when instantiated").

The gap is worst in the stdlib, where a generic exists to be called by code that
does not exist yet, and worst *felt* in the editor, where the author of the
template is looking straight at it.

## Non-goal: synthetic instantiations

Instantiating a template with a made-up concrete `$T` is the obvious strategy
and the wrong one. There is no witness type: a body that writes `v.deinit()`,
`xs.push(v)` or `a == b` fails against any concrete pick, so the pass would
report errors that are not there. False positives in an editor are worse than
silence - they get switched off, and then there is neither.

## Approach: check the template once against a rigid `$T`

Bind each type parameter to a fresh rigid variable (a skolem: a type that
unifies with itself and nothing else), check the body, and report only what
cannot depend on what `T` turns out to be. Every pick whose receiver or argument
is rigid parks instead of failing; parking machinery exists for open type
variables (`checker.f`, the `TieByOpenVar` path) but is a tie-break, not a mode.

What that catches:

- pattern shapes the projector could not read (E2115 - **landed early**, see
  below)
- unknown free identifiers, unreachable code, malformed control flow
- arity and argument types against a known non-generic callee
- the whole ownership pass (RFC-028): `move` on a non-lvalue, assignment over a
  live binding, use after move. None of it needs to know what `T` is.

What it can never catch, by construction: anything dispatched on `T` - a member
call, an operator, a UFCS pick. Those need the instantiation and stay where they
are.

## Landed early: E2115 at projection

The pattern case needed none of the above. `Pattern.Error` is built by the
projector from the token run (`lib/flang_parser/src/projector.f`), which is a
fact about the source and not about any type, but the only reporter was
`check_pattern`. Moving the report to `error_pattern` in the projector covers
every body, checked or not, in the compiler as well as the editor.

`project_module` takes an optional diagnostic sink for it. A consumer that wants
only the shape passes null.

## Sequencing

1. **E2115 at projection.** Done.
2. **A rigid-`T` mode on `check_function_body`**, off by default, reporting the
   type-independent set. Decide the set's boundary first; see Open questions.
3. **Park picks on a rigid receiver** rather than failing them, so the body can
   be walked to the end without cascading.
4. **Run it from `flang check` and the LSP**, not the LSP alone. If CI cannot
   see it, the stdlib keeps shipping broken generics and the editor is the only
   thing that knows.
5. **Replace the silence test** (`checker.f`, "generic template bodies only
   report when instantiated") with one that asserts the split: a type-independent
   error surfaces, a member-dispatched one still waits for the instantiation.

## Open questions

- Where exactly is the boundary of "cannot depend on `T`"? Operator resolution
  when both operands are rigid is the awkward case.
- Does the rigid pass share `check_function_body`, or is it a separate walk?
- A template instantiated later is then checked twice. Is the rigid pass's
  diagnostic suppressed at the instantiation, or deduplicated by span?
- Does the pass run for every generic in the dependency closure, or only for
  modules the demand already touches (RFC-022)?
