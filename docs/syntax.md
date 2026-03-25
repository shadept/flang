# FLang Syntax Reference

If something is not listed here, it does not exist in FLang.

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
| No semicolons | Statements end at newline | `;` required |
| No `while` | Use `loop` + `break` | `while cond { }` |
| No `mut` keyword | `let` is already mutable | `let mut` |
| No `impl` blocks | UFCS resolves methods from free functions | `impl Type { }` |
| No traits | `#interface` / `#implement` source generators | `trait Foo { }` |
| No closures | Lambdas exist but cannot capture | closures capture env |
| No `elif`/`else if` | Chain `else if` (two keywords) | `elif` |

## Types

**Primitives:** `i8` `i16` `i32` `i64` `u8` `u16` `u32` `u64` `usize` `isize` `f32` `f64` `bool`

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
| `fn(T1, T2) R` | Function type |
| `Type(T)` | Runtime type descriptor |

## Literals

```
42          3.14         true false null
42i32       3.14f32      1.5e10       0xff      1_000_000
"hello"     b'\n'
[1, 2, 3]   [0; 10]     (1, 2)       (1,)      // trailing comma = single-element tuple
```

Escape sequences: `\n` `\t` `\r` `\\` `\"` `\0`

## Variables

```
let x = 10               // mutable, type inferred
let x: i32 = 10          // mutable, explicit type
const X = 42             // immutable
```

`const` at file scope = module-level constant. `let` inside functions only.

## Functions

```
fn add(a: i32, b: i32) i32 { return a + b }
pub fn main() i32 { return 0 }              // pub = visible outside file
fn greet(name: String, times: i32 = 1) {}   // default parameter
```

**Named arguments:** `sub(b = 3, a = 10)` — positional args first, then named.

**Variadic:** `fn sum(..nums: i32) i32` — received as `i32[]` slice. One variadic, must be last. Foreign uses C-style `...` instead.

**Generic:** `$T` introduces, `T` refers. Example: `fn identity(x: $T) T { return x }`

**Foreign:** `#foreign fn malloc(size: usize) &u8?` — no body, C calling convention, not mangled.

**Lambda:** `fn(x: i32, y: i32) i32 { x + y }` — no name after `fn`. Cannot capture. Parameter types inferred when context available.

## Structs

```
struct Point { x: i32, y: i32 }
struct Pair(T) { first: T, second: T }          // generic
type Vec2 = struct { x: i32, y: i32 }           // alternative syntax

let p = Point { x = 10, y = 20 }                // construction (= not :)
let a = .{ x = 10, y = 20 }                     // anonymous (type from context)
let p2 = Point { x, y = 20 }                    // shorthand: x = x
```

Commas between fields optional. Field assignment uses `=`.

## Enums

```
enum Color { Red, Green, Blue }
enum Result(T, E) { Ok(T), Err(E) }             // generic with payloads
type JsonError = enum { UnexpectedChar, UnexpectedEnd }  // alternative syntax

// Naked enum (C-style integers, no payloads allowed):
enum Ord { Less = -1, Equal = 0, Greater = 1 }

let c = Color.Red          // qualified
let r = Result.Ok(42)      // with payload
let r2 = Ok(42)            // short form when unambiguous
```

Commas between variants optional.

## Control Flow

```
// if (expression — can return a value)
let x = if a > b { a } else { b }
if condition { do_thing() }
if a { foo } else if b { bar } else { baz }

// for-in (only kind of for loop)
for item in collection { process(item) }
for i in 0..5 { /* 0,1,2,3,4 */ }

// loop (infinite, use break/continue)
loop { if done { break } }

// match (postfix)
let result = cmd match {
    Quit => 0
    Move(x, y) => x + y
    Write(s) => s.len as i32
    else => -1
}

// defer (LIFO at scope exit)
defer close(handle)
```

`if` without `else` as expression yields `Option` of the body type. Parentheses around conditions optional.

### Iterator Protocol

`for x in collection` desugars to calling `iter(&collection)` then `next(&iterator)` returning `T?`. Make a type iterable by defining `fn iter(self: &T) Iterator` and `fn next(self: &Iterator) Element?`.

## Operators

| Precedence | Operators |
|---|---|
| 11 | `*` `/` `%` |
| 10 | `+` `-` |
| 9 | `&` (bitwise AND) |
| 8 | `^` (XOR) |
| 7 | `\|` (OR) |
| 6 | `..` |
| 5 | `<` `>` `<=` `>=` |
| 4 | `==` `!=` |
| 3 | `and` |
| 2 | `or` |
| 1 | `??` (right-assoc) |

- `and`/`or` are keywords, short-circuit, bool only
- `!expr` logical NOT, `&expr` address-of (both prefix unary)
- `a ?? b` unwraps optional or uses fallback
- `a?.field` optional chaining
- `expr as Type` casting (numeric, pointer, String/u8[])

### Operator Overloading

All operators desugar to function calls: `op_add`, `op_sub`, `op_multiply`, `op_divide`, `op_modulo`, `op_band`, `op_bor`, `op_bxor`, `op_eq`, `op_ne`, `op_lt`, `op_gt`, `op_le`, `op_ge`, `op_index`, `op_set_index`, `op_coalesce`, `op_assign`, `op_add_assign`.

`op_eq` auto-derives `op_ne`. `op_cmp(a, b) Ord` auto-derives all six comparison operators.

## References and UFCS

```
let ptr = &x           // take reference
let val = ptr.*        // explicit dereference
let f = ptr.field      // auto-deref (recursive through &&T)
```

Any function with first param `T` or `&T` can be called as `value.func()`. This is how methods work — no `impl` blocks.

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

## Tuples

```
let t: (i32, bool) = (42, true)
let x = t.0            // desugars to t._0
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
