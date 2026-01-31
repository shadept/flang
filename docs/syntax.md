# FLang Syntax Reference

This document is the complete syntax reference for FLang. Every construct the language supports is listed here. If something is not listed, it does not exist in FLang.

## What FLang Does NOT Have

No semicolons. No `while` loops. No `mut` keyword. No `->` return type arrow. No `impl` blocks. No traits/interfaces. No closures. No string interpolation. No multi-line comments. No default parameter values. No `elif`. No ternary operator. No `switch`/`case`. No macros. No `async`/`await`. No destructuring assignment. No spread operator. No variadic functions (except `#foreign`). No type aliases.

## Comments

```
// single line comment (only kind)
```

## Primitive Types

`i8` `i16` `i32` `i64` `u8` `u16` `u32` `u64` `usize` `isize` `bool`

No floating-point types.

## Composite Types

| Written as | Meaning |
|---|---|
| `String` | UTF-8 string (ptr + len) |
| `[T; N]` | Fixed-size array of N elements |
| `T[]` | Slice (fat pointer: ptr + len) |
| `&T` | Non-null reference |
| `T?` | Optional (equivalent to `Option(T)`) |
| `&T?` | Nullable reference (equivalent to `Option(&T)`) |
| `(A, B)` | Tuple (sugar for `{ _0: A, _1: B }`) |
| `()` | Unit (empty tuple) |
| `fn(T1, T2) R` | Function/Lambda type |
| `Type(T)` | Runtime type descriptor |

## Literals

```
42              // integer (type inferred from context)
true false      // bool
null            // None value for optionals
"hello"         // string (UTF-8, null-terminated)
[1, 2, 3]      // array literal
[0; 10]         // array repeat: 10 elements, all 0
(1, 2)          // tuple
(1,)            // single-element tuple (trailing comma required)
(x)             // grouped expression (NOT a tuple)
```

**Escape sequences in strings:** `\n` `\t` `\r` `\\` `\"` `\0`

## Variable Declarations

```
let x = 10               // mutable, type inferred
let x: i32 = 10          // mutable, type explicit
const X = 42             // immutable
const X: i32 = 42        // immutable, type explicit
```

`const` at file scope = module-level constant. `let` inside functions only.

## Functions

```
fn add(a: i32, b: i32) i32 {
    return a + b
}

pub fn main() i32 {
    return 0
}
```

- `pub` makes the function visible outside the file.
- Return type goes after `)` with NO arrow, NO colon.
- No return type means void.

### Generic Functions

`$T` introduces a type parameter. It can appear anywhere in the parameter list or return type.

```
fn identity(x: $T) T {
    return x
}

fn make_pair(a: $T, b: $U) (T, U) {
    return (a, b)
}
```

`$T` binds the type. Subsequent uses of `T` (without `$`) refer to the bound type.

### Foreign Functions

```
#foreign fn malloc(size: usize) &u8?
#foreign fn printf(fmt: &u8, ...) i32
```

No body. C calling convention. Name not mangled. Variadic `...` allowed only here.

## Structs

```
struct Point {
    x: i32
    y: i32
}
```

Commas between fields are optional. Generic structs:

```
struct Pair(T) {
    first: T
    second: T
}
```

### Construction

```
let p = Point { x = 10, y = 20 }       // named struct
let a = .{ x = 10, y = 20 }            // anonymous struct (type from context)
```

Field assignment uses `=`, not `:`.

## Enums

```
enum Color {
    Red
    Green
    Blue
}

enum Result(T, E) {
    Ok(T)
    Err(E)
}
```

Commas between variants are optional. Variants can carry payloads in parentheses or be bare (unit variants).

### Naked Enums (C-style integers)

```
enum Ord {
    Less = -1
    Equal = 0
    Greater = 1
}
```

When any variant has `= value`, the enum is naked: all variants are integer-tagged, none may carry payloads. Tags auto-increment if omitted.

### Variant Construction

```
let c = Color.Red               // qualified
let r = Result.Ok(42)           // qualified with payload
let r2 = Ok(42)                 // short form (when unambiguous)
```

## Control Flow

### If Expression

Parentheses around the condition are **required**.

```
let x = if (a > b) a else b

if (condition) {
    do_thing()
}

if (a) foo
else if (b) bar
else baz
```

`if` without `else` used as expression yields `Option` of the body type.

### For Loop

Only `for`-`in`. No `while`. No C-style `for`.

```
for (item in collection) {
    process(item)
}

for (i in 0..5) {
    // i = 0, 1, 2, 3, 4
}
```

Loop body can be a block or single expression. `break` and `continue` work inside.

### Iterator Protocol

`for`-`in` works on any type that implements `iter()` and `next()`. The loop:

```
for (x in collection) { body }
```

desugars to:

```
let it = iter(&collection)
// loop:
let n = next(&it)       // returns T?
if (n == null) break
let x = n               // unwrapped value
body
```

To make a type iterable, define two free functions:

```
struct MyIterator {
    // iterator state
}

fn iter(self: &MyCollection) MyIterator {
    return .{ /* initial state */ }
}

fn next(self: &MyIterator) Element? {
    if (done) return null
    // advance state
    return value
}
```

`iter()` returns an iterator struct. `next()` returns `T?` — the next value, or `null` to signal end. Both are regular functions found via UFCS.

### Match Expression

`match` is postfix: scrutinee comes first.

```
let result = cmd match {
    Quit => 0,
    Move(x, y) => x + y,
    Write(s) => s.len as i32,
    else => -1
}
```

Arms use `=>`. Commas between arms are optional. Patterns:

| Pattern | Example |
|---|---|
| Unit variant | `Quit` |
| Payload variant | `Move(x, y)` |
| Qualified variant | `Color.Red` |
| Nested | `Some(Ok(x))` |
| Wildcard | `_` |
| `else` | default arm |

All variants must be covered, or `else` is required.

### Defer

```
defer close(handle)
```

Runs at scope exit. Multiple defers execute in LIFO order.

### Break / Continue

```
for (i in 0..10) {
    if (i == 5) break
    if (i % 2 == 0) continue
}
```

### Return

```
return value
return          // void return
```

## Operators

### Precedence (highest to lowest)

| Level | Operators |
|---|---|
| 8 | `*` `/` `%` |
| 7 | `+` `-` |
| 6 | `..` |
| 5 | `<` `>` `<=` `>=` |
| 4 | `==` `!=` |
| 3 | `and` |
| 2 | `or` |
| 1 | `??` (right-associative) |

- `and` / `or` are keywords, not symbols. Short-circuit. Bool operands only.
- `!expr` is logical NOT (prefix, unary).
- `&expr` takes address of a variable.

### Null Operators

```
a ?? b          // if a has value, unwrap it; otherwise b
a?.field        // if a has value, access field; otherwise null
```

### Casting

```
expr as Type
```

Works for: numeric conversions, pointer-to-integer, pointer-to-pointer, `String`/`u8[]`.

### Operator Overloading

All operators desugar to function calls. Define these to overload:

| Operator | Function name |
|---|---|
| `+` | `op_add` |
| `-` | `op_sub` |
| `*` | `op_multiply` |
| `/` | `op_divide` |
| `%` | `op_modulo` |
| `==` | `op_eq` |
| `!=` | `op_ne` |
| `<` | `op_lt` |
| `>` | `op_gt` |
| `<=` | `op_le` |
| `>=` | `op_ge` |
| `[]` read | `op_index` |
| `[] =` write | `op_set_index` |
| `??` | `op_coalesce` |
| `=` | `op_assign` |
| `+=` | `op_add_assign` |

**Auto-derivation:** defining `op_eq` auto-derives `op_ne` (and vice versa). Defining `op_cmp(a, b) Ord` auto-derives all six comparison operators.

```
pub fn op_add(lhs: &Vec2, rhs: Vec2) Vec2 { ... }
pub fn op_cmp(lhs: &Box, rhs: Box) Ord { ... }
```

## References and Auto-Dereference

```
let ptr = &x           // take reference
let val = ptr.*        // explicit dereference (copy)
let f = ptr.field      // auto-dereference (no copy, reads through pointer)
ptr.field = 10         // auto-deref write (modifies pointed-to value)
```

Auto-deref applies recursively: `&&T` accessed via `.field` dereferences twice.

## UFCS (Unified Function Call Syntax)

Any function whose first parameter is `T` or `&T` can be called with dot syntax:

```
fn len(s: &String) usize { ... }

let n = s.len()         // desugars to len(&s)
```

If the first parameter is `&T`, the receiver is automatically referenced. This is how methods work - there are no `impl` blocks.

## Imports

```
import core.string
import std.io
```

Each file is a module. Path segments map to directories and filenames.
Core modules dont need to explicitly imported, `core.produle` is auto imported on all files, which includes all other core modules.

## Test Blocks

```
import std.test

test "addition" {
    assert_eq(2 + 3, 5, "math works")
}
```

Test blocks are module-scoped, not exported. Multiple per file. Run with `--test` flag. Available assertions: `assert_true(bool, String)`, `assert_eq($T, T, String)`.

## Visibility

- `pub fn`, `pub struct`, `pub enum`: visible outside the defining file.
- Without `pub`: visible only within the defining file.
- Struct fields are writable only within the defining file (read-only externally).

## Tuples

```
let t: (i32, bool) = (42, true)
let x = t.0            // access first element (desugars to t._0)
let y = t.1            // access second element
```

Tuples are anonymous structs with fields `_0`, `_1`, etc. Structurally typed.

## Type Literals

```
let t: Type(i32) = i32
let s = t.size          // size in bytes
let n = t.name          // "i32"
```

## Assignment

```
x = 10                  // simple assignment
arr[i] = 42            // index assignment (calls op_set_index)
ptr.field = 5          // field write through reference
```

Compound assignment: `+=` (others not yet implemented).
