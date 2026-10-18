# FLang Syntax Reference

This document is a derived quick reference. The canonical source of truth is
[spec.md](spec.md) — when the two disagree, spec.md wins. If something is not
listed here, it does not exist in FLang.

## FLang is NOT Rust

| Concept | FLang | NOT this |
|---|---|---|
| Generics | `Option(T)`, `List(String)`, `Result(T, E)` | `Option<T>`, `Option[T]` |
| Type params | `fn foo(x: $T) T` (`$` binds, then `T` refers) | `fn foo<T>(x: T) -> T` |
| Return type | `fn foo() i32 { ... }` (after `)`, no arrow) | `fn foo() -> i32` |
| Mutability | `let` is mutable, `const` is immutable | `let` immutable, `let mut` |
| Match | `x match { A => ..., else => ... }` (postfix) | `match x { A => ... }` |
| Optionals | `T?` or `&T?`, null value is `null` | `Option<T>`, `None` |
| Deref | `ptr.*` | `*ptr` |
| Methods | UFCS — free functions with `self: &T` first param | `impl` blocks |
| Optional semicolons | Statements end at newline | `;` required |
| No `mut` keyword | `let` is already mutable | `let mut` |
| No `impl` blocks | UFCS resolves methods from free functions | `impl Type { }` |
| No traits | `#interface` / `#implement` source generators | `trait Foo { }` |
| Lambdas | `{ x => x * 2 }`, `xs.map { it * 2 }`, `f(a) { p => ... }` (trailing) | `\|x\| x * 2`, `move \|x\|` |
| Case is syntax | Types start uppercase, functions lowercase: `Point { x = 1 }` constructs, `spawn { ... }` passes a lambda | free naming |
| Closures capture by reference | Every captured name is a reference to the enclosing binding (RFC-033); no capture-list syntax | `move` closures, capture lists |
| No `elif`/`else if` | Chain `else if` (two keywords) | `elif` |
| Associated types | `I.Item`, `Iterator(Item = i32)` | `I::Item`, `<I as Iterator>::Item`, `Iterator<Item = i32>` |
| Scoped runtime state | `context(allocator = &a) { ... }` rebinds a declared field for a block | thread-locals, `with` blocks, global setters |

## Types

**Primitives:** `i8` `i16` `i32` `i64` `isize` `u8` `u16` `u32` `u64` `usize` `f32` `f64` `bool` `char` `void` `never`

| Syntax | Meaning |
|---|---|
| `String` | UTF-8 string (ptr + len) |
| `[T; N]` | Fixed-size array |
| `T[]` | Slice (ptr + len) |
| `&T` | Non-null reference |
| `T?` | Optional (`Option(T)`) |
| `&T?` | Nullable reference (`Option(&T)`) |
| `(A, B)` | Tuple (sugar for `{ _0: A, _1: B }`) |
| `()` | Unit |
| `fn(T1, T2) R` | Function type; `fn(move T) R` takes ownership of its argument |
| `Type(T)` | Runtime type descriptor |

## Literals

```
42          3.14         true false null
42i32       3.14f32      1.5e10       0xff      1_000_000
"hello"     b'\n'
[1, 2, 3]   [0; 10]     (1, 2)       (1,)      // trailing comma = single-element tuple
```

Escape sequences: `\n` `\t` `\r` `\\` `\"` `\0`

## String Interpolation

Prefix a string with `$` to embed expressions. Three forms:

```
$"hello {name}"              // OwnedString via fresh StringBuilder (context.allocator)
$(64)"hi {who}"              // fresh builder with initial capacity
$(&alloc)"k={k}"             // fresh builder with custom allocator
$(cap, &alloc)"x={x}"        // both capacity and allocator positional
$(allocator=&alloc)"..."     // named builder args work
$sb"append {x} into sb"      // void — appends into existing builder/writer
```

Segments and holes use different lexing rules:

- **Segments** (text between holes) use normal string escapes (`\n \t \r \\ \" \0 \uXXXX`), plus `{{` → `{` and `}}` → `}`.
- **Holes** (`{ expr }`) contain full expressions with the normal grammar. Strings inside a hole use their own quoting: `$"{msg.contains("foo")}"` works; `\"` at the hole's top level is invalid.
- **Format specs** (text after `:` inside a hole) are captured verbatim and passed as a `String` to `append(sb, val, spec)`. `{x:04}` pads `x` to 4 digits. Float specs take an optional trailing presentation type: `e` / `E` for scientific notation (`{x:.3e}` → `2.500e-03`) and `a` for the exact C99 hex-float form (`{x:a}` → `0x1.8p+0`, round-trips every bit); no type char is fixed-point.

No whitespace is allowed between `$` and its `(`, identifier, or `"`. The expression desugars to `StringBuilder.append(...)` calls — user types gain format support by defining `fn format(self: T, sb: &StringBuilder, spec: String)`.

## Variables

```
let x = 10               // mutable, type inferred
let x: i32 = 10          // mutable, explicit type
const X = 42             // immutable
```

`const` at file scope = module-level constant. `let` inside functions only.

## Runtime Context

```
pub context allocator: &Allocator = &global_allocator   // file scope; type and default required
context depth: u32 = 0                                  // module-private

context.depth                                // read a field
let saved = context                          // copy, type `Context`
context(depth = context.depth + 1) { run() } // rebind for the body; an expression
context(saved, depth = 0) { run() }          // positional base first, then named fields
```

`context` is a keyword. After it, `(` opens a rebind, `.` reads a field, anything else is a copy. The rebind body is a block: `return`, `?`, `break` and `defer` act as in any block. See spec §4.4.

## Functions

```
fn add(a: i32, b: i32) i32 { return a + b }
pub fn main() i32 { return 0 }              // pub = visible outside file
fn greet(name: String, times: i32 = 1) {}   // default parameter
fn close(h: move File) {}                   // takes ownership: `h.close()` moves `h`
```

**Parameter modes (RFC-033):** `x: T` reads, `x: &T` shares, `x: move T` takes ownership. The call site carries no marker: `close(move h)` is E2129.

**Named arguments:** `sub(b = 3, a = 10)` — positional args first, then named.

**Variadic:** `fn sum(..nums: i32) i32` — received as `i32[]` slice. One variadic, must be last. Foreign uses C-style `...` instead.

**Generic:** `$T` introduces, `T` refers. Example: `fn identity(x: $T) T { return x }`

**Bounds:** `fn max(s: $T[]) T? where T: copyable`, `where I: Iterator, F: fn(I.Item) bool`, `where T: Eq + Hash`, `where I: Iterator, I.Item: Hash` - a bound is a contract (see Contracts); `where` is contextual. A trailing comma after the last bound is allowed. A struct's, enum's or contract's bounds sit on its parameter list instead (see Structs).

**Foreign:** `#foreign fn malloc(size: usize) &u8?` — no body, C calling convention, not mangled.

**Lambda:** `{ x, y => x + y }`, `{ p: &u8 => ... }`, `{ => work() }`, arrow-less `{ it * 2 }` (RFC-039). No return-type slot. In a call's parentheses a `{` always opens a lambda; elsewhere only when `=>`, `ident =>`, `ident ,` or `ident :` follows it. A trailing lambda follows a call's `)` or a lowercase name on the same line (`xs.fold(0i32) { a, b => a + b }`, `run { 7 }`) and fills the last callable parameter, every later one defaulted; in an `if`/`while`/`for` header parenthesize it. Captures enclosing names by reference (RFC-033): the body reads and writes the enclosing bindings. Capturing lambdas synthesise an anonymous callable type and cannot decay into a bare `fn(...) Ret` slot — pass them through a generic parameter (`fn apply(f: $F, ...)`) instead. Parameter types inferred when context available. The legacy `fn(x: i32) i32 { ... }` expression is still accepted until migration.

## Type Aliases

```
type VarId = u32                 // transparent — VarId and u32 are interchangeable
type Buf = [u8; 16]
pub type Pair = (i32, i32)       // pub follows module visibility rules
```

`type Name = <type-expr>` introduces a transparent alias when the RHS is not a `struct(...) { ... }` / `enum(...) { ... }` builder. No nominal identity, no conversion at use sites. Cyclic aliases (`type A = B; type B = A`) error with E2036.

## Contracts

```
pub type Iterator = contract {
    type Item                             // associated type, solved from the requirements
    fn next(self: &Self) Item?            // requirement: callable on `Self`
}
pub type Iterable = contract {
    type Iter: Iterator                   // solved, then held to its bound
    type Item = Iter.Item                 // derived
    fn iter(self: &Self) Iter
}
pub type Into = contract(T: copyable) {   // a parameter, bounded in place
    fn into(self: Self) T
}
pub type Key = copyable + Hash + Eq       // `+` combines contracts

fn first(it: move $I) I.Item? where I: Iterator                    // projection
fn total(it: move $I) i32 where I: Iterator(Item = i32)            // pinned
fn to_set(it: move $I) Set(I.Item) where I: Iterator(Item: Hash + Eq)   // bounded
fn read(b: &$B) T where B: contract { fn get(self: &Self) $T } { ... }   // anonymous
```

`contract` is a keyword. `X.Item` in type position is a projection: the associated type `Item` of `X`'s contract, for a type parameter `X`, `Self`, or another projection (`C.Iter.Item`). In a contract application `Item = T` pins an associated type and `Item: B` bounds it; both follow the positional arguments. A requirement is a function declaration without a body; one per line (commas optional), its return type on the `)`'s line. `Self` is the constrained type inside a contract, and the declared type applied to its own parameters inside a named struct or enum (`next: &Self?`). A contract has no values: bound a type parameter with it.

## Structs

```
type Point = struct { x: i32, y: i32 }
type Pair = struct(T) { first: T, second: T }                // generic
type Filtered = struct(I: Iterator, F: fn(I.Item) bool) {    // bounded parameters
    it: I
    f: F
}
type Color = #foreign struct { r: u8, g: u8, b: u8, a: u8 }  // C FFI struct
type Vec128 = #simd struct { _data: [u8; 16] }               // SIMD-aligned

let p = Point { x = 10, y = 20 }                // construction (= not :)
let a = .{ x = 10, y = 20 }                     // anonymous (type from context)
let p2 = Point { x, y = 20 }                    // shorthand: x = x
```

Commas between fields optional. Field assignment uses `=`. A parameter's bound sits on it (`T: Bound`); `where` after a type's parameter list is E2145. The legacy `struct Name { ... }` declaration form has been removed (E1050) — see RFC-008.

## Enums

```
type Color = enum { Red, Green, Blue }
type Result = enum(T, E) { Ok(T), Err(E) }                   // generic with payloads
type JsonError = enum { UnexpectedChar, UnexpectedEnd }

// Naked enum (C-style integers, no payloads allowed):
type Ord = enum { Less = -1, Equal = 0, Greater = 1 }

let c = Color.Red          // qualified
let r = Result.Ok(42)      // with payload
let r2 = Ok(42)            // short form when unambiguous
```

Commas between variants optional. The legacy `enum Name { ... }` declaration form has been removed (E1051) — see RFC-008.

## Control Flow

```
// if (expression — can return a value)
let x = if a > b { a } else { b }
if condition { do_thing() }
if a { foo } else if b { bar } else { baz }

// for-in (only kind of for loop). Parens around the header are NOT permitted.
for item in collection { process(item) }
for &item in collection { item.* = ... }   // by reference: `item: &T`, via `iter_ref`
for i in 0..5 { /* 0,1,2,3,4 */ }    // half-open: `..` only, no `..=`

// loop (infinite, use break/continue)
loop { if done { break } }

// while (predicate at loop head, condition must be bool)
while n < 10 { n = n + 1 }

// match (postfix) — see RFC-010 for the full pattern grammar
let result = cmd match {
    Quit | Halt        => 0,                    // or-pattern
    Move(x, y) if x > 0 => x + y,               // guard
    Move(x, y)         => -x - y,               // same pattern, no guard
    Write(s)           => s.len as i32,
    else               => -1
}

// tuple destructuring
let dispatch = (op, n) match {
    (Op.Add, 0)   => "noop",
    (Op.Add, n)   => "add",
    (_, _)        => "other",
}

// struct destructuring (strict — every field, or `..`)
let area = rect match {
    Rect { width = 0, .. }      => 0,
    Rect { width, height }      => width * height,
}

// range patterns — `..` half-open, `..=` inclusive (pattern-only token). A `..` opening a line
// starts a new range; a range expression keeps `..` on its left operand's line.
let bucket = n match {
    ..0      => -1,
    0        => 0,
    1..=9    => 1,
    10..=99  => 2,
    100..    => 3,
}

// defer (LIFO at scope exit)
defer close(handle)
```

An `if` without an `else` is not an expression and yields no value; only `if`/`else` produces one. Parentheses around conditions optional: a header is keyword, expression, block. The expression is ordinary except that the body's `{` ends it rather than starting a struct literal or block - and only at the header's own nesting level, so `if take(P { x = 1 }) > 0 { ... }` and `if (a + b) * 4 > 6 { ... }` both parse.

### Iterator Protocol

`for x in collection` desugars to calling `iter(&collection)` then `next(&iterator)` returning `T?`. Make a type iterable by defining `fn iter(self: &T) Iterator` and `fn next(self: &Iterator) Element?`. `for &x in collection` calls `iter_ref(&collection)` instead (then `next` returning `&T?`), binding `x` as a reference into the collection - `List` and slices provide it; `for x in xs.iter_ref()` is the explicit spelling.

## Operators

| Precedence | Operators |
|---|---|
| 13 | `as` (postfix typed cast) |
| 12 | `*` `/` `%` |
| 11 | `+` `-` |
| 10 | `<<` `>>` `>>>` |
| 9 | `&` (bitwise AND) |
| 8 | `^` (XOR) |
| 7 | `\|` (OR) |
| 6 | `..` |
| 5 | `<` `>` `<=` `>=` |
| 4 | `==` `!=` |
| 3 | `and` |
| 2 | `or` |
| 1 | `??` (right-assoc) |
| 0 | `match` (postfix, lowest) |

- `as` binds tighter than every binary operator: `a + b as i32` is `a + (b as i32)`.
- `match` binds looser than every binary operator: `a + b match { ... }` is `(a + b) match { ... }`.
- `>>` is arithmetic shift (sign-preserving); `>>>` is logical shift (zero-fills).
- A literal shift count must be within the left operand's bit width (E2121): `u8_val << 18` is an error, `(u8_val as u32) << 18` is not.
- `and`/`or` are keywords, short-circuit, bool only
- `!expr` logical NOT, `~expr` bitwise NOT, `&expr` address-of (all prefix unary)
- `~` is integer-only (error on `bool` and floats); `!` is `bool`-only
- `a ?? b` unwraps optional or uses fallback
- `a?.field` optional chaining
- `expr?` postfix early-return — desugars to `op_try(expr) match { Continue(v) => v, Return(r) => return r }`. `?.` (single token) always wins over `?` followed by `.`; use `(expr?).field` for "early-return then access". Forbidden inside `defer`. See RFC-009.
- `expr as Type` casting (numeric, pointer, String/u8[])

### Operator Overloading

All operators desugar to function calls: `op_add`, `op_sub`, `op_multiply`, `op_divide`, `op_modulo`, `op_band`, `op_bor`, `op_bxor`, `op_bnot`, `op_eq`, `op_ne`, `op_lt`, `op_gt`, `op_le`, `op_ge`, `op_index`, `op_set_index`, `op_coalesce`, `op_assign`, `op_add_assign`, `op_deref`, `op_try`.

`op_eq` auto-derives `op_ne`. `op_cmp(a, b) Ord` auto-derives all six comparison operators.

`op_deref` enables transparent field access through wrapper types:
```
fn op_deref(self: &Wrapper($T)) &T { return &self.__value }
// enables: wrapper.field  (transparently accesses inner T's fields)
```

## References and UFCS

```
let ptr = &x           // take reference
let val = ptr.*        // explicit dereference
let f = ptr.field      // auto-deref (recursive through &&T)
```

Any function with first param `T` or `&T` can be called as `value.func()`. This is how methods work — no `impl` blocks.

`&` in a parameter is a statement of intent, not a mechanism. Every aggregate already crosses by
pointer, so `fn area(s: Shape)` and `fn area(s: &Shape)` emit the same code for a body that only
reads. Write `&` when the body mutates the argument or keeps its address; write the plain type
otherwise. Taking a by-value parameter's address and handing it to a callee is what brings the
shadow copy back (spec §3.2), so `&` on the outer parameter is also how you say "do not copy this
on my account".

An address may be read as an integer (`p as usize`, warns W2004) but never rebuilt from one
(`n as &T` is E2122). `0usize as &T` is the exception, and is how a null reference is spelled.

## Directives

```
#foreign fn write(fd: i32, buf: &u8, n: usize) isize
#deprecated("use `bar`") fn foo() {}
#allow(W2004)
fn is_null(p: &u8) bool { return p as usize == 0 }
```

Directives attach to the declaration that follows. `#allow(CODE, ...)` silences those diagnostic
codes for everything inside that declaration, whichever compiler phase raised them. There is no
file-level or statement-level form.

## Imports and Visibility

```
import std.io.file
import std.list
```

Each file is a module. Core modules are auto-imported. `pub` makes items visible outside the defining file. Struct fields are read-only externally (writable only in defining file).

## Test Blocks

```
test "name" {
    assert_eq(2 + 3, 5, "math works")
    assert_true(x > 0, "positive")
}
```

Module-scoped, not exported. Run with `--test`. Requires `import std.test`.

## Comments

`// line comment to end of line` is the only comment form. There is no `/* */` block comment and no `///` doc comment.

### Doc comments

A contiguous block of `//` lines immediately preceding a declaration is its **doc comment**. No special prefix (`///` etc.); the position attaches the meaning. Tooling treats it as the canonical authored documentation for the declaration.

```
// Token — the lexer's output unit, carrying its own trivia.
//
// Every byte of the source belongs to exactly one Token's leading trivia,
// text, or trailing trivia.
pub type Token = struct { ... }
```

**Shape.** The same shape Javadoc, rustdoc, pydoc and XML doc comments settled on, written in plain `//` lines — there are no `@param`-style tags and no tool parses sections out:

1. A one-line summary, in the third person (`Creates an owned copy of a string view.`).
2. A blank `//`, then the behaviour a caller needs: what it does to its arguments, what it allocates, what it consumes.
3. A `- \`name\`:` bullet per parameter whose contract is not obvious from its type — edge cases, ownership, what null means. Skip parameters that need nothing said.
4. What it returns, who owns it, and what it panics on.

Short items collapse: a total function with a self-evident signature is entitled to a single summary line, and that is the common case. Write the sections a reader would otherwise have to read the body to learn.

**Do not** narrate the implementation's history (why an earlier approach was replaced — that is the commit message's job), restate the signature, or repeat conventions that hold everywhere in the tree (an allocator parameter defaulting to `context.allocator` is only worth a line where the choice has a consequence, as it does when the result outlives the call).

A blank line between the comment block and the declaration breaks the attachment — that comment becomes a free-floating note. Trailing comments after the same-line declaration are not doc comments.

Surfaced by:
- The self-hosted LSP (`lib/flang_lsp`, `flang lsp`) on hover, completion items, and signature help.
- The doc generator (planned `tools/doc`).
- The formatter, which preserves doc-comment formatting verbatim.

Doc comments live on the CST as leading trivia of the declaration's first token (see `lib/flang_parser/src/trivia.f`). Any tool can recover them from the CST without re-parsing.

## Tuples

```
let t: (i32, bool) = (42, true)
let x = t.0            // desugars to t.__0 (double-underscore avoids colliding with user fields)
```

## Source Generators

Compile-time code generation, prefixed with `#`.

```
// Define:
#define(name, Param1: Kind, Param2: Kind) { /* template body */ }

// Invoke:
#name(arg1, arg2)
```

Parameter kinds: `Ident`, `Type`. Last param can be variadic: `..Param: Kind`.

**Directives inside generators:** `#(expr)` interpolation, `#for var in collection { }`, `#if condition { } #else { }`.

**Built-in generators:**

| Generator | Purpose |
|---|---|
| `#derive(T, eq, clone, debug, hash)` | Derive implementations for type |
| `#enum_utils(E)` | Generate `to_string`/`from_string` for enum |
| `#interface(Name, Spec)` | Define vtable-based interface |
| `#implement(Impl, Iface)` | Implement interface for a type |

Generator args can include inline anonymous types: `#interface(Writer, struct { write: fn(data: u8[]) usize })`.
