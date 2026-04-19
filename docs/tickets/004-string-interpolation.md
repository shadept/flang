# RFC-004: String Interpolation

**Type:** Feature (language syntax + frontend)
**Status:** Proposed
**Depends on:** None

## Summary

Add `$"..."` string interpolation to FLang as pure syntactic sugar over the existing `std.string_builder` API. Three prefix forms:

| Form | Result | Use case |
|---|---|---|
| `$"..."` | `OwnedString` via a fresh `StringBuilder` (global allocator) | Ad-hoc message construction |
| `$(args)"..."` | `OwnedString` via a fresh `StringBuilder(args...)` | Custom allocator / pre-sized buffer |
| `$sb"..."` | `void`, appends into existing `sb` (or any `Writer`) | Zero-alloc building, diagnostic-style output |

No runtime component. No stdlib changes required (existing `StringBuilder` already has `append(sb, val)` and `append(sb, val, spec)` overloads for every primitive, plus a generic fallback `append(sb, val: $T, spec)` that dispatches to `val.format(sb, spec)`).

## Motivation

Today, any non-trivial formatted string is built manually:

```flang
let sb = string_builder(64)
sb.append("error[E")
sb.append(code, "04")
sb.append("]: unresolved `")
sb.append(name)
sb.append("` at ")
sb.append(span.line)
sb.append(":")
sb.append(span.col)
```

After:

```flang
$sb"error[E{code:04}]: unresolved `{name}` at {span.line}:{span.col}"
```

This is the dominant shape of diagnostic code in the existing C# compiler, and will be the dominant shape of diagnostic code when we self-host.

## Finalized Syntax

### Segments vs holes — two distinct languages

**Segments** (text between interp boundaries) — string land:
- Normal string escapes: `\n \t \r \\ \" \0 \uXXXX`
- Segment-only escapes: `{{` → literal `{`, `}}` → literal `}`
- `\"` is required since an unescaped `"` ends the interp string

**Holes** (content between `{` and matching `}`) — expression land:
- Full FLang expression grammar, no special rules
- Contain normal string literals `"..."` with their own escapes
- `\"` at the hole's top level is **invalid** (just as in any other expression context)
- Nested `{` / `}` follow normal depth rules (block expressions, anon struct literals, etc.)

**Format spec** — raw text between `:` and the hole's closing `}`:
- No escapes, no parsing — captured verbatim as a `String` literal passed to `append(sb, val, spec)`.
- May not contain `}` (terminator).

### Examples

| Source | Segments | Holes |
|---|---|---|
| `$"hello"` | `["hello"]` | `[]` |
| `$"hi {name}"` | `["hi ", ""]` | `[name]` |
| `$"{a}+{b}={a+b}"` | `["", "+", "=", ""]` | `[a, b, a+b]` |
| `$"she said \"hi\""` | `[she said "hi"]` | `[]` |
| `$"use {{braces}}"` | `[use {braces}]` | `[]` |
| `$"{msg.contains("foo")}"` | `["", ""]` | `[msg.contains("foo")]` |
| `$"{x + 1:03}"` | `["", ""]` | `[(x+1, spec="03")]` |
| `$"{ if c { 1 } else { 2 } }"` | `["", ""]` | `[if c { 1 } else { 2 }]` |

Invalid:
- `$"{msg.starts_with(\"foo\")}"` — `\"` is not a token at expression top-level
- `$"unterminated` — unterminated interp string (E1xxx)
- `$"{unterminated"` — unterminated hole (E1xxx)

### Builder-args form dispatch rule

Inside `$(...)`, the args forward to `string_builder(capacity: usize = 0, allocator: &Allocator? = null)`:

| Form | Forwards to |
|---|---|
| `$""` | `string_builder()` |
| `$(64)""` | `string_builder(64)` |
| `$(&alloc)""` | `string_builder(allocator=&alloc)` — single `&Allocator`-typed arg routes to allocator slot |
| `$(64, &alloc)""` | `string_builder(64, &alloc)` |
| `$(allocator=&alloc)""` | named kwargs work |

Single-arg dispatch is type-directed: if the sole positional arg type-checks as `usize`/integer → capacity; if it type-checks as `&Allocator` or `&Allocator?` → allocator. This check runs at desugar time, after expression inference on the arg.

## Implementation

### Phase 1 — Lexer (src/FLang.Frontend/Lexer.cs, TokenKind.cs)

**New token kinds** (add to `TokenKind.cs`):
- `InterpStringStart` — emitted on `$"` (and on the opening `"` after `$(...)` or `$ident`)
- `InterpSegment` — token value is the decoded segment text; may be empty
- `InterpHoleStart` — emitted on unescaped `{` in segment mode
- `InterpHoleEnd` — emitted on unmatched `}` in hole mode
- `InterpFormatSep` — emitted on `:` at hole depth 0
- `InterpFormatSpec` — raw text between `:` and matching `}`; token value is the spec
- `InterpStringEnd` — emitted on the closing `"`

**Lexer state machine** — add a mode stack. Three modes:

1. **Segment mode**: entered on `InterpStringStart`. Reads characters, applies string escapes, handles `{{`/`}}` as literal braces, accumulates into a segment buffer. On single `{` → flush segment (emit `InterpSegment`), emit `InterpHoleStart`, push hole mode (depth=0). On unescaped `"` → flush segment, emit `InterpStringEnd`, pop mode. On EOF → error E1xxx "unterminated interp string".

2. **Hole mode**: runs the normal lexer to produce tokens. Local `_holeDepth` counter starts at 0. Each emitted `OpenBrace` / `OpenParenthesis` / `OpenBracket` increments the bracket-type stack; matching closers decrement. When a `}` is about to be emitted and the brace depth would go to -1 → emit `InterpHoleEnd` instead (consume the `}`), pop back to segment mode. When a `:` is about to be emitted at top level of the hole → emit `InterpFormatSep` instead, switch to format-spec mode. Tokens for nested `(...)` or `[...]` track their own depths normally (a `:` inside a nested `(...)` is NOT a format separator).

3. **Format-spec mode**: raw character capture. Reads chars until matching `}` (no escape handling, no nesting). Emits `InterpFormatSpec(raw_text)`, `InterpHoleEnd`, returns to segment mode.

**Triggers for segment mode entry**:
- `$"` (immediately, no whitespace between `$` and `"`) — lexer handles inline.
- `$(args)"` and `$ident"` — parser-driven: parser calls `_lexer.MarkNextStringInterp()` immediately before `Eat(...)` of the closing `)` or the `Identifier`. The lexer's scan loop checks this flag when it next encounters `"` and enters interp mode.

**No whitespace allowed** between `$` and its suffix (`"`, `(`, or identifier). Enforced by the lexer's lookahead. This avoids ambiguity with bare `$` (which only appears in type position for `$T`).

### Phase 2 — AST (src/FLang.Frontend/Ast/Expressions/)

**New file: `InterpolatedStringExpressionNode.cs`**

```csharp
public class InterpolatedStringExpressionNode : ExpressionNode
{
    public InterpolatedStringExpressionNode(
        SourceSpan span,
        IdentifierExpressionNode? targetIdentifier,
        List<ExpressionNode>? builderArgs,
        List<InterpPart> parts) : base(span)
    {
        TargetIdentifier = targetIdentifier;
        BuilderArgs = builderArgs;
        Parts = parts;
    }

    // Form 3 ($sb"..."): the target identifier. Null for forms 1 and 2.
    public IdentifierExpressionNode? TargetIdentifier { get; }

    // Form 2 ($(args)"..."): builder args (may include NamedArgumentExpressionNode).
    // Null for forms 1 and 3. Empty list allowed (but equivalent to form 1).
    public List<ExpressionNode>? BuilderArgs { get; }

    // Alternating segments and expressions. Always starts with a segment and
    // ends with a segment. If N expressions, there are N+1 segments.
    public List<InterpPart> Parts { get; }
}

public abstract class InterpPart
{
    public SourceSpan Span { get; protected set; }
}

public class InterpSegmentPart : InterpPart
{
    public InterpSegmentPart(SourceSpan span, string text) { Span = span; Text = text; }
    public string Text { get; }
}

public class InterpExpressionPart : InterpPart
{
    public InterpExpressionPart(SourceSpan span, ExpressionNode expression, string? formatSpec)
    { Span = span; Expression = expression; FormatSpec = formatSpec; }
    public ExpressionNode Expression { get; set; } // mutable for coercion insertion
    public string? FormatSpec { get; }
}
```

### Phase 3 — Parser (src/FLang.Frontend/Parser.cs)

**Entry point**: in `ParsePrimaryExpression` around line 1815, add a `case TokenKind.Dollar:` branch that dispatches to `ParseInterpolatedString()`.

**`ParseInterpolatedString` flow**:

```
Eat(Dollar)
IdentifierExpressionNode? target = null
List<ExpressionNode>? builderArgs = null

if _current == InterpStringStart:
    // form 1: $"..."
    // (no prefix consumed beyond `$`)
else if _current == OpenParenthesis:
    // form 2: $(args)"..."
    Eat(OpenParenthesis)
    builderArgs = ParseCallArguments()  // reuse existing
    _lexer.MarkNextStringInterp()        // tell lexer before advancing
    Eat(CloseParenthesis)                // advance triggers next-token scan
else if _current == Identifier:
    // form 3: $ident"..."
    target = new IdentifierExpressionNode(ident span, ident text)
    _lexer.MarkNextStringInterp()
    Eat(Identifier)
else:
    // error: "expected '\"', '(', or identifier after '$'"

Eat(InterpStringStart)
parts = []
while _current != InterpStringEnd:
    if _current == InterpSegment:
        parts.Add(new InterpSegmentPart(span, Eat(InterpSegment).Text))
    else if _current == InterpHoleStart:
        Eat(InterpHoleStart)
        expr = ParseExpression()   // normal expression parser; stops at InterpFormatSep / InterpHoleEnd
        spec: string? = null
        if _current == InterpFormatSep:
            Eat(InterpFormatSep)
            spec = Eat(InterpFormatSpec).Text
        Eat(InterpHoleEnd)
        parts.Add(new InterpExpressionPart(span, expr, spec))
    else: error
Eat(InterpStringEnd)

return new InterpolatedStringExpressionNode(span, target, builderArgs, parts)
```

**Normalization**: if `parts` starts with a non-segment (shouldn't happen from lexer output) or has consecutive segments (also shouldn't happen), normalize by inserting empty segments so invariant `seg expr seg expr ... seg` holds. Alternatively, enforce the invariant at parse time and error if violated.

The existing `ParseExpression` does not need modification — `InterpFormatSep` and `InterpHoleEnd` naturally terminate expression parsing because they don't start any primary expression or continue any operator chain.

### Phase 4 — Desugar (src/FLang.Semantics/HmTypeChecker.Expressions.cs)

**Add case in `InferExpression` switch** (~line 25):
```csharp
InterpolatedStringExpressionNode interp => InferInterpolation(interp),
```

**`InferInterpolation(interp)` strategy**: rewrite to an equivalent `BlockExpressionNode` (forms 1, 2) or statement sequence (form 3), then recursively call `InferExpression` on the rewritten tree. This gives free overload resolution on `append` and free type inference on hole expressions.

**Form 1 & 2 rewrite** (return `OwnedString`):

```
({
    let __sb = string_builder(<args resolved below>)
    defer __sb.deinit()
    __sb.append(<segment 0 as String>)
    __sb.append(<expr 0>[, <spec 0>])
    __sb.append(<segment 1 as String>)
    ...
    __sb.to_string()
})
```

Notes:
- `__sb` is a synthesized identifier, use a monotonic counter (e.g. `__interp_sb_N`) to avoid shadowing.
- Each segment becomes a `StringLiteralNode`. Empty segments produce `__sb.append("")` calls — the desugar can omit these as an optimization (skip segment parts with empty text).
- Each hole becomes `__sb.append(expr)` (no spec) or `__sb.append(expr, "spec")` (with spec, passed as `StringLiteralNode`).
- The block's trailing expression is `__sb.to_string()`.
- **`defer __sb.deinit()` is emitted immediately after builder construction.** In the happy path, `to_string()` transfers ownership (sets `sb.cap=0`), so the deferred `deinit` is a no-op. In the panic path (e.g. a hole expression panics before `to_string()` runs), deinit frees the live buffer — no leak on exceptional exit. Relies on the Phase 5 fixes.

**Form 2 arg resolution** (single-arg type-directed dispatch):
- If `BuilderArgs.Count == 1` and the arg is positional (not a `NamedArgumentExpressionNode`):
  - Infer the arg's type.
  - If it unifies with `&Allocator` or `&Allocator?` → rewrite as `NamedArgumentExpressionNode(name="allocator", value=arg)` before passing to `string_builder`.
  - Else (integer-ish) → leave as-is (positional → capacity slot).
- Multi-arg or already-named: pass through verbatim.
- This logic lives in `InferInterpolation`, before building the `CallExpressionNode` for `string_builder(...)`.

**Form 3 rewrite** (return `void`, appends into target):

```
// statement sequence, no block wrapper needed if context allows:
target.append(<segment 0 as String>)
target.append(<expr 0>[, <spec 0>])
target.append(<segment 1 as String>)
...
```

Since this is called in expression position but produces void, wrap in a `BlockExpressionNode` with no trailing expression:

```
({
    target.append(...)
    target.append(...)
    ...
})  // block has no trailing expr → void type
```

Target-identifier resolution is done via normal `IdentifierExpressionNode` lookup — no new logic needed.

### Phase 5 — `to_string()` ownership transfer (fixed in this RFC)

Rewrite `StringBuilder.to_string()` (no-arg) as a true ownership transfer. No new allocation, no copy. The buffer already in `sb` becomes the `OwnedString`'s buffer.

The single bug in doing this correctly: **zero `sb.cap` alongside `sb.ptr` and `sb.len`**. Leaving `cap` non-zero would make a subsequent `sb.deinit()` try to dealloc a buffer that's already been transferred.

```flang
pub fn to_string(sb: &StringBuilder) OwnedString {
    const alloc = sb.allocator.or_global()

    // Ensure room for null terminator. In the common case cap > len
    // already (StringBuilder grows in powers of 2), so reserve is a no-op.
    if sb.cap == sb.len {
        sb.reserve(1)
    }

    const term = sb.ptr + sb.len
    term.* = 0

    const result = OwnedString {
        ptr = sb.ptr,
        len = sb.len,
        allocator = alloc,
    }

    sb.ptr = 0usize as &u8
    sb.len = 0
    sb.cap = 0
    return result
}
```

The two-arg `to_string(allocator)` variant at [`stdlib/std/string_builder.f:105`](../../stdlib/std/string_builder.f:105) is out of scope for this RFC.

#### Why this is load-bearing for interpolation

With `sb.cap = 0` after transfer, the desugar can emit `defer __sb.deinit()` immediately after builder construction:

- **Happy path**: `to_string()` transfers ownership, `sb.cap = 0`, the deferred `deinit` short-circuits on `sb.cap > 0`.
- **Panic path**: if a hole expression panics before `to_string()` runs, defer fires on the live SB, freeing the buffer. No leak on exceptional exit.

### Phase 6 — Tests (tests/FLang.Tests/Harness/interpolation/)

New harness directory. At minimum:

- `basic.f` — `$"hello {name}"` prints "hello world"
- `literal_braces.f` — `$"{{ {x} }}"` prints "{ 42 }"
- `quotes_in_segment.f` — `$"say \"hi\""`
- `string_in_hole.f` — `$"{msg.contains("x")}"`
- `format_spec_int.f` — `$"{42:04}"` prints "0042"
- `format_spec_float.f` — `$"{3.14:.2}"` prints "3.14"
- `format_spec_hex.f` — `$"{255:x}"` prints "ff"
- `multiple_holes.f` — `$"{a}+{b}={a+b}"`
- `expr_in_hole.f` — `$"{ if c { 1 } else { 2 } }"`
- `nested_braces.f` — anon struct or block inside hole
- `alloc_form.f` — `$(&alloc)"..."` with a fixed_buffer_allocator
- `capacity_form.f` — `$(64)"..."`
- `both_args.f` — `$(64, &alloc)"..."`
- `named_args.f` — `$(allocator=&alloc)"..."`
- `append_into_builder.f` — `$sb"..."` form 3
- `append_into_writer.f` — `$w"..."` where w is a `Writer` (buffered or otherwise) — verifies generic `append` dispatch works
- `user_format.f` — user type with `fn format(self, sb, spec)` works through interp
- Error tests:
  - `error_unterminated_string.flang`
  - `error_unterminated_hole.flang`
  - `error_unescaped_quote_in_hole.flang`
  - `error_bad_prefix.flang` (e.g. `$123"..."`)

**Phase 5 tests** (in `tests/FLang.Tests/Harness/string_builder/`):
- `to_string_transfers_ownership.f` — build SB with `test_allocator`, call `to_string()`, assert `sb.cap == 0` and `test_allocator.alloc_count` unchanged across the call (transfer, not copy).
- `deinit_after_to_string_is_noop.f` — `sb.to_string()` then `sb.deinit()`, assert `test_allocator.dealloc_count` unchanged (nothing for sb to free).
- `owned_string_full_lifecycle.f` — SB → OwnedString via `to_string()` → `OwnedString.deinit()`, assert `check_leaks() == 0`.

Follow existing `.f` / `.flang` test conventions (see `tests/FLang.Tests/Harness/string_builder/` for reference, and `tests/FLang.Tests/Harness/basics/` for basic conventions).

### Phase 7 — Docs

- **`docs/syntax.md`** — add "String Interpolation" section under Literals. Cover all three forms, segment/hole escape rules, format spec.
- **`docs/spec.md`** — add semantics section describing the desugar equivalence.
- **`docs/error-codes.md`** — register the new error codes (E1xxx range for parse errors).
- **`docs/known-issues.md`** — remove the stale `writer.f duplicate definitions` entry (already verified stale in this session). Optionally note the `StringBuilder.to_string` leak as a separate known issue if not fixed alongside.

## Ordering

1. **Phase 5 first** — Fix `to_string` / `OwnedString` correctness. Add `cap` field, fix deinits, update dict fakes. This must land and tests pass before the desugar can rely on `defer sb.deinit()` being safe.
2. Phase 5 tests green.
3. TokenKind + lexer changes (new tokens, mode state, flag for parser cooperation).
4. Lexer unit tests (can be done in the harness via observing tokenization errors, or by adding a dedicated lexer test if one exists).
5. AST node + InterpPart types.
6. Parser changes (ParseInterpolatedString + Dollar case).
7. Desugar in type checker.
8. Harness tests (build incrementally as phases 5-7 land).
9. Docs update.
10. Full test suite green — `dotnet test.cs`.

## Risks / pitfalls

- **Lexer mode stack correctness**: the most complex change. Bugs here are hard to debug. Write lexer-level tests first if possible; otherwise rely on harness tests that exercise every form + nested case.
- **`Mark...Interp()` timing**: the flag must be set BEFORE `Eat(...)` advances the token. If set after, the next `"` has already been scanned as a regular string. Verify the lexer reads tokens lazily (one at a time), which it appears to.
- **Bracket depth tracking in hole mode**: must handle `(...)`, `[...]`, and `{...}` independently. A `)` at parenthesis depth 0 should NOT close the hole; only a `}` at brace depth 0 does.
- **Format spec edge cases**: `{x:}` (empty spec) should be valid and equivalent to `{x}`. `{x: }` (whitespace-only spec) is passed to `append` as `" "` — the SB's `parse_int_spec` handles leading whitespace by treating it as literal. Decide whether to trim or pass verbatim. **Recommendation: pass verbatim** to match `.NET`/Rust behavior where spec is opaque.
- **Parser re-entrance during hole expression parsing**: ensure the parser's `_stopAtBrace` flag (used for `if`/`for` without parens — see Parser.cs:1806) doesn't accidentally trip on hole-inner block expressions. Since we're inside an interp hole, `_stopAtBrace` should be false when starting the hole.
- **Empty segment optimization**: the lexer emits `InterpSegment("")` between consecutive holes and at string start/end. The desugar should skip these to avoid no-op `append("")` calls. Safe optimization, do it.
- **Interaction with `$T` generic binding**: `$T` is type-position only (parser.cs:2469 is in `ParseType`). Expression-position `$` has no prior use, so no conflict.
- **Empty interp string `$""`**: should produce an empty `OwnedString`. Verify the desugar handles zero-hole zero-segment case cleanly (after empty-segment optimization, the block is `{ let __sb = string_builder(); __sb.to_string() }`).

## Out of scope

- String interpolation for raw/multi-line strings (FLang has no raw-string syntax today).
- Positional holes `{0}`, `{1}` — not needed given identifier access.
- Named holes `{name=expr}` — redundant with bare identifier holes.
- Localization / i18n hooks.
- Fixing `StringBuilder.to_string` buffer leak (separate ticket).
- Adding `while` as a real keyword (tangentially noted stale in known-issues — separate cleanup).
