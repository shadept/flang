# FLang Compiler Error Codes

This document provides a comprehensive reference for all compiler error codes used in FLang. Error codes follow the
pattern `EXXXX` where `XXXX` is a four-digit number indicating the compiler phase and error type.

## Error Code Numbering Scheme

FLang uses a custom sequential numbering system organized by compiler phase:

- **E0XXX**: CLI and infrastructure errors (module loading, C compiler invocation)
- **E1XXX**: Frontend errors (lexing, parsing, syntax)
- **E2XXX**: Semantic analysis errors (type checking, name resolution, control flow)
- **E3XXX**: Code generation errors (FIR lowering, C code generation)

Within each category, error codes are assigned sequentially starting from E0001, E1001, E2001, E3001, etc. This ensures
no gaps and no bias in numbering.

---

## E0XXX: CLI and Infrastructure Errors

### E0000: Internal CLI Error

**Category**: CLI
**Severity**: Error

#### Description

A catch-all error code for CLI and infrastructure failures that don't fit other categories. This includes:

- No functions found in any module
- C compiler configuration missing
- C compiler invocation failure

#### Example

```
error[E0000]: No functions found in any module
error[E0000]: C compiler (gcc) failed: ...
```

#### Solution

Check that your source files contain at least one function and that a C compiler is available on your system.

---

### E0001: Module Not Found

**Category**: Module Loading
**Severity**: Error

#### Description

An `import` statement referenced a module that could not be found in the standard library or project directory.

#### Example

```flang
import nonexistent.module  // ERROR: cannot find module `nonexistent.module`
```

#### Solution

Check that the module path is correct and that the file exists under stdlib or the project directory.

---

### E0002: Circular Import

**Category**: Module Loading
**Severity**: Error

#### Description

A module attempted to import itself, creating a circular dependency.

#### Example

```flang
// In file mymodule.f
import mymodule  // ERROR: module imports itself
```

#### Solution

Remove the self-import or restructure your module dependencies.

---

## E1XXX: Frontend Errors (Lexing & Parsing)

### E1001: Unexpected Token

**Category**: Parsing
**Severity**: Error

#### Description

An unexpected token was encountered in the current parsing context. The diagnostic includes the found token and the context when available.

#### Example

```flang
pub fn main() i32 {
    let x: i32 = 42;  // ERROR: unexpected token `;` (semicolons not required)
    return x
}
```

#### Solution

Remove the unexpected token or check the syntax:

```flang
pub fn main() i32 {
    let x: i32 = 42  // OK: no semicolon
    return x
}
```

---

### E1002: Expected Token Mismatch

**Category**: Parsing
**Severity**: Error

#### Description

The parser expected a specific token but found a different one. This commonly occurs with missing delimiters or keywords.

#### Example

```flang
pub fn main() i32 {
    let x: i32 = 42  // ERROR: expected `}`, found end of file
    return x
// Missing closing brace
```

#### Solution

Add the expected token:

```flang
pub fn main() i32 {
    let x: i32 = 42
    return x
}  // OK: closing brace present
```

---

### E1004: Invalid Array Length

**Category**: Parsing / Types
**Severity**: Error

#### Description

An array type like `[T; N]` used a non-integer length `N`.

#### Example

```flang
pub fn main() i32 {
    let arr: [i32; "five"] = [1, 2, 3, 4, 5]  // ERROR: array length must be an integer
    return 0
}
```

#### Solution

Use an integer literal for the array length:

```flang
pub fn main() i32 {
    let arr: [i32; 5] = [1, 2, 3, 4, 5]  // OK: integer length
    return 0
}
```

---

### E1005: Invalid Array Repeat Count

**Category**: Parsing / Literals
**Severity**: Error

#### Description

An array repeat literal like `[value; count]` used a non-integer repeat `count`.

#### Example

```flang
pub fn main() i32 {
    let arr: [i32; 5] = [0; "five"]  // ERROR: repeat count must be an integer
    return 0
}
```

#### Solution

Use an integer literal for the repeat count:

```flang
pub fn main() i32 {
    let arr: [i32; 5] = [0; 5]  // OK: integer repeat count
    return 0
}
```

---

<!-- E1006 removed: expression statements are now supported generally -->

## E2XXX: Semantic Analysis Errors

### E2001: Cannot Infer Type

**Category**: Type Inference
**Severity**: Error

#### Description

The compiler cannot infer the type of a variable because it has a compile-time type (`comptime_int` or `comptime_float`)
that must be resolved to a concrete type. Type annotations are required.

#### Example

```flang
pub fn main() i32 {
    let x = 42  // ERROR: cannot infer type, variable has comptime type `comptime_int`
    return x
}
```

#### Solution

Add an explicit type annotation:

```flang
pub fn main() i32 {
    let x: i32 = 42  // OK: explicit type annotation
    return x
}
```

---

### E2002: Mismatched Types

**Category**: Type Checking
**Severity**: Error

#### Description

A value of one type was provided where a different type was expected. This is the most common type error and can occur
in many contexts:

- Variable initialization
- Function return values
- Binary operations
- Comparisons
- If/else branches
- Assignments

#### Examples

**Variable Initialization:**

```flang
let x: i32 = "hello"  // ERROR: expected `i32`, found `String`
```

**Function Return:**

```flang
pub fn getNumber() i32 {
    return "not a number"  // ERROR: expected `i32`, found `String`
}
```

**Binary Operations:**

```flang
let result: i32 = 10 + "hello"  // ERROR: cannot apply operator to `i32` and `String`
```

**If Conditions:**

```flang
if (42) {  // ERROR: expected `bool`, found `comptime_int`
    // ...
}
```

**If/Else Branches:**

```flang
let x: i32 = if (true) 10 else "hello"  // ERROR: branches have incompatible types
```

**Range Bounds:**

```flang
for (i in "start".."end") {  // ERROR: range bounds must be integers
    // ...
}
```

#### Solution

Ensure types match:

```flang
let x: i32 = 42  // OK: types match
let s: String = "hello"  // OK: types match
if (true) { ... }  // OK: boolean condition
```

---

### E2003: Cannot Find Type in Scope

**Category**: Name Resolution
**Severity**: Error

#### Description

A type name was used but no type with that name exists in the current scope. This typically occurs when:

- The type name is misspelled
- The type hasn't been imported
- The type doesn't exist

#### Example

```flang
pub fn main() MyCustomType {  // ERROR: cannot find type `MyCustomType` in this scope
    return 0
}
```

#### Solution

Use a valid type name:

```flang
pub fn main() i32 {  // OK: i32 is a built-in type
    return 0
}
```

Or import the type if it's in another module:

```flang
import mylib.types

pub fn main() MyCustomType {
    // ...
}
```

---

### E2004: Cannot Find Value in Scope

**Category**: Name Resolution
**Severity**: Error

#### Description

A variable, function, or value name was used but no value with that name exists in the current scope. This occurs when:

- The name is misspelled
- The variable hasn't been declared
- The function hasn't been defined or imported
- The name is out of scope

#### Examples

**Undefined Variable:**

```flang
pub fn main() i32 {
    return x  // ERROR: cannot find value `x` in this scope
}
```

**Undefined Function:**

```flang
pub fn main() i32 {
    return getNumber()  // ERROR: cannot find function `getNumber` in this scope
}
```

#### Solution

**For variables**, declare them first:

```flang
pub fn main() i32 {
    let x: i32 = 42
    return x  // OK: x is declared
}
```

**For functions**, define or import them:

```flang
pub fn getNumber() i32 {
    return 42
}

pub fn main() i32 {
    return getNumber()  // OK: getNumber is defined
}
```

---

### E2005: Variable Already Declared

**Category**: Name Resolution
**Severity**: Error

#### Description

A variable was declared twice in the same scope with the same name. Each variable name can only be declared once per
scope.

#### Example

```flang
pub fn main() i32 {
    let x: i32 = 10
    let x: i32 = 20  // ERROR: variable `x` is already declared
    return x
}
```

#### Solution

Use different names or use assignment instead of re-declaration:

```flang
pub fn main() i32 {
    let x: i32 = 10
    x = 20  // OK: assignment, not declaration
    return x
}
```

Or use different names:

```flang
pub fn main() i32 {
    let x: i32 = 10
    let y: i32 = 20  // OK: different name
    return x + y
}
```

---

### E2006: Break Statement Outside Loop

**Category**: Control Flow
**Severity**: Error

#### Description

A `break` statement was used outside of a loop context. The `break` statement can only be used inside `for` loops to
exit the loop early.

#### Example

```flang
pub fn main() i32 {
    break  // ERROR: `break` statement outside of loop
    return 0
}
```

#### Solution

Remove the `break` statement or move it inside a loop:

```flang
pub fn main() i32 {
    for (i in 0..10) {
        if (i == 5) {
            break  // OK: inside loop
        }
    }
    return 0
}
```

---

### E2007: Continue Statement Outside Loop

**Category**: Control Flow
**Severity**: Error

#### Description

A `continue` statement was used outside of a loop context. The `continue` statement can only be used inside `for` loops
to skip to the next iteration.

#### Example

```flang
pub fn main() i32 {
    continue  // ERROR: `continue` statement outside of loop
    return 0
}
```

#### Solution

Remove the `continue` statement or move it inside a loop:

```flang
pub fn main() i32 {
    for (i in 0..10) {
        if (i == 2) {
            continue  // OK: inside loop
        }
        // ...
    }
    return 0
}
```

---

### E2008: Range Expression Outside Loop

**Category**: Control Flow
**Severity**: Error

#### Description

A range expression (`a..b`) was used outside of a `for` loop context. Range expressions are currently only supported as
the iterable in `for` loops.

#### Example

```flang
pub fn main() i32 {
    let x: i32 = 0..10  // ERROR: range expressions can only be used in for loops
    return x
}
```

#### Solution

Use range expressions only in `for` loops:

```flang
pub fn main() i32 {
    for (i in 0..10) {  // OK: range in for loop
        // ...
    }
    return 0
}
```

---

### E2009: For Loop Only Supports Ranges

**Category**: Control Flow / Iterators
**Severity**: Error

#### Description

A `for` loop attempted to iterate over a non-range expression. Currently, FLang only supports range expressions (`a..b`)
as the iterable in `for` loops. Support for iterating over other types (arrays, slices, custom iterators) will be added
in future milestones.

#### Example

```flang
pub fn main() i32 {
    let list: i32 = 42
    for (x in list) {  // ERROR: for loops currently only support range expressions
        // ...
    }
    return 0
}
```

#### Solution

Use a range expression:

```flang
pub fn main() i32 {
    for (i in 0..10) {  // OK: range expression
        // ...
    }
    return 0
}
```

---

### E2010: Assignment to Undeclared Variable

**Category**: Name Resolution
**Severity**: Error

#### Description

An assignment was attempted to a variable that has not been declared with `let`. In FLang, variables must be declared
before they can be assigned to.

#### Example

```flang
pub fn main() i32 {
    x = 42  // ERROR: cannot assign to `x` because it is not declared
    return x
}
```

#### Solution

Declare the variable first with `let`:

```flang
pub fn main() i32 {
    let x: i32 = 0
    x = 42  // OK: x was declared above
    return x
}
```

---

### E2011: Function Argument Count Mismatch

**Category**: Type Checking
**Severity**: Error

#### Description

A function was called with the wrong number of arguments. The number of arguments provided must match the number of
parameters declared in the function signature.

#### Example

```flang
pub fn add(a: i32, b: i32) i32 {
    return a + b
}

pub fn main() i32 {
    return add(10)  // ERROR: function `add` expects 2 argument(s) but 1 were provided
}
```

#### Solution

Provide the correct number of arguments:

```flang
pub fn add(a: i32, b: i32) i32 {
    return a + b
}

pub fn main() i32 {
    return add(10, 5)  // OK: correct number of arguments
}
```

---

### E2012: Cannot Dereference Non-Reference Type

**Category**: Type Checking / Pointers
**Severity**: Error

#### Description

An attempt was made to dereference a value that is not a reference type. The dereference operator (`.*`) can only be
applied to reference types (`&T` or `&T?`).

#### Example

```flang
pub fn main() i32 {
    let x: i32 = 42
    return x.*  // ERROR: cannot dereference non-reference type, expected `&T` or `&T?`, found `i32`
}
```

#### Solution

Only dereference reference types:

```flang
pub fn main() i32 {
    let x: i32 = 42
    let ptr: &i32 = &x
    return ptr.*  // OK: ptr is a reference type
}
```

---

### E2013: Type Not Found

**Category**: Type Checking
**Severity**: Error

#### Description

This error occurs when the compiler expects a specific type to be present, but it cannot be found in the current scope. This is most common when using string literals, which require the `String` type from `core.string`.

#### Example

```flang
pub fn main() i32 {
    let s: String = "hello"  // ERROR: String type not found, make sure to import core/string
    return 0
}
```

#### Solution

Import the missing type:

```flang
import core.string

pub fn main() i32 {
    let s: String = "hello"  // OK: String type is imported
    return s.len
}
```

---

### E2014: Field Access Error

**Category**: Type Checking / Structs
**Severity**: Error

#### Description

This error occurs when attempting to access a field that doesn't exist on a type, or when attempting to access a field on a non-struct type.

#### Examples

**Non-existent Field:**

```flang
struct Point {
    x: i32,
    y: i32
}

pub fn main() i32 {
    let p: Point = Point { x: 10, y: 20 }
    return p.z  // ERROR: no field `z` on type `Point`
}
```

**Access on Non-struct Type:**

```flang
pub fn main() i32 {
    let x: i32 = 42
    return x.field  // ERROR: cannot access field on non-struct type `i32`
}
```

#### Solution

Ensure the field exists on the type being accessed, or that the type is a struct.

---

### E2015: Intrinsic Requires Exactly One Type Argument

**Category**: Compiler Intrinsics
**Severity**: Error

#### Description

The `size_of` or `align_of` intrinsic was called with an incorrect number of arguments. These intrinsics require exactly one type argument.

#### Example

```flang
#foreign fn size_of(t: Type($T)) usize

pub fn main() i32 {
    let size: usize = size_of()  // ERROR: `size_of` requires exactly one type argument
    return size as i32
}
```

#### Solution

Pass exactly one type argument:

```flang
#foreign fn size_of(t: Type($T)) usize

pub fn main() i32 {
    let size: usize = size_of(i32)  // OK: one type argument
    return size as i32
}
```

---

### E2016: Intrinsic Argument Must Be Type Name

**Category**: Compiler Intrinsics
**Severity**: Error

#### Description

The `size_of` or `align_of` intrinsic requires a type name as its argument, not an expression or variable.

#### Example

```flang
#foreign fn size_of(t: Type($T)) usize

pub fn main() i32 {
    let x: i32 = 42
    let size: usize = size_of(x)  // ERROR: `size_of` argument must be a type name
    return size as i32
}
```

#### Solution

Pass a type name, not a variable or expression:

```flang
#foreign fn size_of(t: Type($T)) usize

pub fn main() i32 {
    let size: usize = size_of(i32)  // OK: i32 is a type name
    return size as i32
}
```

---

### E2017: Unknown Type in Intrinsic

**Category**: Compiler Intrinsics / Name Resolution
**Severity**: Error

#### Description

The type name passed to `size_of` or `align_of` is not defined or not in scope.

#### Example

```flang
#foreign fn size_of(t: Type($T)) usize

pub fn main() i32 {
    let size: usize = size_of(MyStruct)  // ERROR: unknown type `MyStruct`
    return size as i32
}
```

#### Solution

Define the type before use, or use a built-in type:

```flang
#foreign fn size_of(t: Type($T)) usize

struct MyStruct {
    x: i32,
    y: i32
}

pub fn main() i32 {
    let size: usize = size_of(MyStruct)  // OK: MyStruct is defined
    return size as i32
}
```

---

### E2018: Struct Construction - Invalid Target

**Category**: Type Checking / Structs
**Severity**: Error

#### Description

This error occurs when attempting to construct a value as a struct, but the target type is not a struct, or when an anonymous struct literal is used without a target type that can be inferred.

#### Example

```flang
let x: i32 = i32 { value: 42 } // ERROR: i32 is not a struct
```

#### Solution

Ensure the target type is a struct, or provide a type annotation for anonymous struct literals.

---

### E2019: Struct Construction - Missing Fields

**Category**: Type Checking / Structs
**Severity**: Error

#### Description

This error occurs when a struct construction is missing one or more required fields.

#### Example

```flang
struct Point { x: i32, y: i32 }
let p = Point { x: 10 } // ERROR: missing field `y`
```

#### Solution

Provide all required fields in the struct literal.

---

### E2020: Invalid Cast

Category: Type Checking / Casts
Severity: Error

Description:
An explicit cast `expr as Type` was used where the compiler cannot prove a valid conversion under the language's casting
rules.

Examples:

```flang
let p: &i32 = &x
let y: String = p as String  // ERROR: invalid cast `&i32` to `String`
```

Solution:
Use a valid cast pair (e.g., integer↔integer, `&T`↔`&U`, `&T`↔`usize`, `String`↔`u8[]`) or change the
types/representation to match.

---

### E2021: Type Not Iterable

Category: Iterator Protocol
Severity: Error

Description:
A `for` loop attempted to iterate over a type that doesn't implement the iterator protocol (no `iter` function found).

The iterator protocol requires a function with signature `fn iter(collection: &T) StateType` where `StateType` is any
struct.

Examples:

```flang
struct NoIterator {
    value: i32
}

pub fn main() i32 {
    let x: NoIterator = .{ value = 42 }
    for (i in x) {  // ERROR E2021: type `NoIterator` cannot be iterated (no `iter` function)
        return i
    }
    return 0
}
```

Solution:
Implement the iterator protocol by defining `iter` and `next` functions for the type:

```flang
fn iter(x: &NoIterator) NoIterator {
    return *x
}

fn next(x: &NoIterator) i32? {
    // ... return next element or null
}
```

---

### E2022: No Matching iter Function

Category: Iterator Protocol
Severity: Error

Description:
An `iter` function exists, but none of its overloads match the signature `fn iter(&T)` for the iterable type `T`.

Examples:

```flang
struct MyType { value: i32 }

fn iter(x: MyType) MyType {  // Wrong: takes MyType, not &MyType
    return x
}

for (i in my_val) { }  // ERROR E2022: no `iter(&MyType)` found
```

Solution:
Ensure the `iter` function takes a reference to the collection type:

```flang
fn iter(x: &MyType) MyType {  // Correct: takes &MyType
    return *x
}
```

---

### E2023: Iterator State Missing next Function

Category: Iterator Protocol
Severity: Error

Description:
The `iter` function returns a state type, but no `next` function exists for that state type.

Examples:

```flang
struct MyType { value: i32 }

fn iter(x: &MyType) MyType {
    return *x
}

// Missing: fn next(state: &MyType) Element?

for (i in my_val) { }  // ERROR E2023: type `MyType` has no `next` method
```

Solution:
Implement the `next` function for the iterator state:

```flang
fn next(state: &MyType) i32? {
    if (state.value == 0) return null
    let val = state.value
    state.value = state.value - 1
    return val
}
```

---

### E2024: No Matching next Function

Category: Iterator Protocol
Severity: Error

Description:
A `next` function exists, but none of its overloads match the signature `fn next(&StateType)` for the iterator state
type.

Examples:

```flang
struct MyType { value: i32 }

fn iter(x: &MyType) MyType { return *x }

fn next(state: MyType) i32? {  // Wrong: takes MyType, not &MyType
    return state.value
}

for (i in my_val) { }  // ERROR E2024: no `next(&MyType)` found
```

Solution:
Ensure the `next` function takes a reference to the state type:

```flang
fn next(state: &MyType) i32? {  // Correct: takes &MyType
    return state.value
}
```

---

### E2025: next Must Return Option Type

Category: Iterator Protocol
Severity: Error

Description:
The `next` function must return an Option type (`T?` or `Option(T)`), but it returns a different type.

Examples:

```flang
struct MyType { value: i32 }

fn iter(x: &MyType) MyType { return *x }

fn next(state: &MyType) i32 {  // Wrong: returns i32, not i32?
    return state.value
}

for (i in my_val) { }  // ERROR E2025: found `i32`, expected `Option(T)`
```

Solution:
Return an Option type from `next`:

```flang
fn next(state: &MyType) i32? {  // Correct: returns i32?
    if (state.value == 0) return null
    return state.value
}
```

---

### E2026: Empty Array Inference

**Category**: Type Checking / Arrays
**Severity**: Error

#### Description

This error occurs when the compiler cannot infer the element type of an empty array literal.

#### Example

```flang
let x = [] // ERROR: cannot infer type of empty array literal
```

#### Solution

Add a type annotation:

```flang
let x: i32[] = [] // OK
```

---

### E2027: Invalid Array Index Type

**Category**: Type Checking / Arrays
**Severity**: Error

#### Description

This error occurs when attempting to index into an array or slice with a non-integer value.

#### Example

```flang
let x = [1, 2, 3]
let val = x["0"] // ERROR: array index must be an integer
```

#### Solution

Use an integer for indexing.

---

### E2028: Non-indexable Type

**Category**: Type Checking
**Severity**: Error

#### Description

This error occurs when attempting to use the index operator `[]` on a type that doesn't support indexing (i.e., not an array or slice).

#### Example

```flang
let x: i32 = 42
let val = x[0] // ERROR: cannot index into value of type `i32`
```

#### Solution

Only index into arrays or slices.

---

### E2030: Match on Non-Enum Type

**Category**: Pattern Matching
**Severity**: Error

#### Description

A `match` expression was used on a value that is not an enum type. Match expressions in FLang only support enum types.

#### Example

```flang
struct Point { x: i32, y: i32 }

pub fn main() i32 {
    let p: Point = .{ x = 10, y = 20 }
    return p match {  // ERROR: match requires an enum type, found `Point`
        Point => 0
    }
}
```

#### Solution

Use match expressions only with enum types. For structs, use field access or destructuring.

---

### E2031: Non-Exhaustive Match

**Category**: Pattern Matching
**Severity**: Error

#### Description

A match expression does not cover all variants of an enum and has no `else` clause to handle remaining cases.

#### Example

```flang
enum Value {
    None
    Some(i32)
    Error(i32)
}

pub fn main() i32 {
    let v: Value = Value.Some(5)
    return v match {  // ERROR: non-exhaustive match, missing variants: Error
        None => 0,
        Some(x) => x
    }
}
```

#### Solution

Either add the missing variants or add an `else` clause:

```flang
return v match {
    None => 0,
    Some(x) => x,
    Error(e) => e  // OK: all variants covered
}
// OR
return v match {
    None => 0,
    Some(x) => x,
    else => -1  // OK: else handles remaining cases
}
```

---

### E2032: Match Pattern Arity Mismatch

**Category**: Pattern Matching
**Severity**: Error

#### Description

A match pattern has a different number of bindings than the enum variant expects.

#### Example

```flang
enum Point {
    Origin
    Coordinate(i32, i32)
}

pub fn main() i32 {
    let p: Point = Point.Coordinate(10, 20)
    return p match {
        Origin => 0,
        Coordinate(x) => x  // ERROR: expected 2 bindings, found 1
    }
}
```

#### Solution

Provide the correct number of bindings:

```flang
return p match {
    Origin => 0,
    Coordinate(x, y) => x + y  // OK: 2 bindings for 2-field variant
}
```

---

### E2034: Duplicate Enum Variant Name

**Category**: Type Checking / Enums
**Severity**: Error

#### Description

An enum definition contains multiple variants with the same name.

#### Example

```flang
enum Status {
    Ok
    Error
    Ok  // ERROR: variant names must be unique within an enum
}
```

#### Solution

Use unique names for each variant:

```flang
enum Status {
    Ok
    Error
    Success  // OK: unique name
}
```

---

### E2035: Recursive Type Without Indirection

**Category**: Type Checking / Enums
**Severity**: Error

#### Description

An enum variant directly contains the enum type itself without using a reference. This would create an infinitely-sized
type.

#### Example

```flang
enum Bad {
    Value(i32)
    Recursive(Bad)  // ERROR: recursive types must use references
}
```

#### Solution

Use a reference (`&`) or nullable reference (`&?`) for recursive types:

```flang
enum Good {
    Value(i32)
    Recursive(&Good)  // OK: reference provides indirection
}
```

---

### E2037: Unknown Enum Variant

**Category**: Pattern Matching
**Severity**: Error

#### Description

A match pattern references an enum variant that does not exist in the matched enum type.

#### Example

```flang
enum Color {
    Red
    Green
    Blue
}

pub fn main() i32 {
    let c: Color = Color.Red
    return c match {
        Red => 1,
        Yellow => 2  // ERROR: no variant `Yellow` in enum `Color`
    }
}
```

#### Solution

Use only valid variant names from the enum definition.

---

### E2102: Conflicting Generic Type Bindings

**Category**: Generics
**Severity**: Error

#### Description

During generic function call resolution, a type parameter was inferred to have conflicting concrete types from different
arguments.

#### Example

```flang
pub fn same(a: $T, b: T) T {
    return a
}

pub fn main() i32 {
    let v: i32 = same(1, true)  // ERROR: T mapped to `i32` and `bool`
    return v
}
```

#### Solution

Ensure all arguments that bind to the same type parameter have compatible types:

```flang
let v: i32 = same(1, 2)  // OK: both arguments are integers
```

---

## E3XXX: Code Generation Errors

### E3001: Invalid Type During Lowering

**Category**: Code Generation
**Severity**: Error

#### Description

A struct constructor or null literal was encountered during code generation without a properly resolved type. This
typically indicates a bug in the type checker.

#### Example

This error usually cannot be triggered by user code. If encountered, please report it as a compiler bug.

#### Solution

Report the issue with sample code that reproduces the error.

---

### E3002: Field Access on Unknown Type

**Category**: Code Generation
**Severity**: Error

#### Description

A field access expression was encountered but the base type was not properly resolved during type checking.

#### Example

This error usually indicates an internal compiler issue. It should not occur in normal usage.

#### Solution

Report the issue with sample code that reproduces the error.

---

### E3003: Field Not Found During Lowering

**Category**: Code Generation
**Severity**: Error

#### Description

A field access was attempted on a struct but the field name could not be found. This typically indicates a type
checking bug since field access should be validated earlier.

#### Example

This error usually indicates an internal compiler issue.

#### Solution

Report the issue with sample code that reproduces the error.

---

### E3004: Unresolved Variable or Array Type

**Category**: Code Generation
**Severity**: Error

#### Description

A variable identifier or array literal was encountered without a resolved type. This may indicate a type checker bug.

#### Example

This error usually indicates an internal compiler issue.

#### Solution

Report the issue with sample code that reproduces the error.

---

### E3005: Non-Constant Array Expression

**Category**: Code Generation
**Severity**: Error

#### Description

An array repeat expression `[value; count]` used a non-constant count, or a slice index was used where only array
indexing is currently supported.

#### Example

```flang
pub fn main() i32 {
    let n: i32 = 5
    let arr: [i32; 5] = [0; n]  // ERROR: array repeat count must be constant
    return 0
}
```

#### Solution

Use a constant expression for the repeat count:

```flang
let arr: [i32; 5] = [0; 5]  // OK: constant repeat count
```

---

### E3006: Break Outside Loop (Lowering)

**Category**: Code Generation
**Severity**: Error

#### Description

A `break` statement was encountered outside of a loop context during code generation.

#### Example

```flang
pub fn main() i32 {
    break  // ERROR: break can only be used inside a loop
    return 0
}
```

#### Solution

Use `break` only inside `for` loops.

---

### E3007: Continue Outside Loop (Lowering)

**Category**: Code Generation
**Severity**: Error

#### Description

A `continue` statement was encountered outside of a loop context during code generation.

#### Example

```flang
pub fn main() i32 {
    continue  // ERROR: continue can only be used inside a loop
    return 0
}
```

#### Solution

Use `continue` only inside `for` loops.

---

### E3008: Range Type Error

**Category**: Code Generation
**Severity**: Error

#### Description

A range expression was encountered but did not have the expected Range struct type.

#### Example

This error typically indicates an internal issue with range lowering.

#### Solution

Report the issue with sample code that reproduces the error.

---

### E3010: Missing String Type or Undeclared Variable

**Category**: Code Generation
**Severity**: Error

#### Description

A string literal was used without importing `core.string`, or an assignment was made to an undeclared variable.

#### Examples

**Missing String import:**

```flang
pub fn main() i32 {
    let s: String = "hello"  // ERROR: String type not found, import core.string
    return 0
}
```

**Undeclared variable:**

```flang
pub fn main() i32 {
    x = 42  // ERROR: variable `x` is not declared
    return 0
}
```

#### Solution

Import `core.string` for string literals, or declare variables with `let` before assignment.

---

### E3012: Invalid Address-Of Operation

**Category**: Code Generation
**Severity**: Error

#### Description

The address-of operator `&` was used on an expression that cannot have its address taken.

#### Example

```flang
pub fn main() i32 {
    let ptr = &(1 + 2)  // ERROR: cannot take address of expression
    return 0
}
```

#### Solution

Use `&` only with variable names:

```flang
let x: i32 = 3
let ptr = &x  // OK: taking address of variable
```

---

### E3014: Invalid Function During Lowering

**Category**: Code Generation
**Severity**: Error

#### Description

A function could not be properly lowered to intermediate representation. This usually indicates an internal compiler
issue.

#### Solution

Report the issue with sample code that reproduces the error.

---

### E3037: Enum Variant Lowering Error

**Category**: Code Generation
**Severity**: Error

#### Description

An enum variant construction could not be properly lowered. This typically indicates an issue with enum codegen.

#### Solution

Report the issue with sample code that reproduces the error.

---

## Summary Table

### E0XXX: CLI and Infrastructure

| Code      | Category          | Description                                  |
|-----------|-------------------|----------------------------------------------|
| **E0000** | CLI               | Internal CLI error (placeholder)             |
| **E0001** | Module Loading    | Module not found                             |
| **E0002** | Module Loading    | Circular import                              |

### E1XXX: Frontend (Lexing & Parsing)

| Code      | Category          | Description                                  |
|-----------|-------------------|----------------------------------------------|
| **E1001** | Parsing           | Unexpected token                             |
| **E1002** | Parsing           | Expected token mismatch                      |
| **E1004** | Parsing           | Invalid array length (non-integer)           |
| **E1005** | Parsing           | Invalid array repeat count (non-integer)     |

### E2XXX: Semantic Analysis

| Code      | Category          | Description                                  |
|-----------|-------------------|----------------------------------------------|
| **E2001** | Type Inference    | Cannot infer type (needs annotation)         |
| **E2002** | Type Checking     | Mismatched types                             |
| **E2003** | Name Resolution   | Cannot find type in scope                    |
| **E2004** | Name Resolution   | Cannot find value in scope                   |
| **E2005** | Name Resolution   | Variable already declared                    |
| **E2006** | Control Flow      | Break statement outside loop                 |
| **E2007** | Control Flow      | Continue statement outside loop              |
| **E2008** | Control Flow      | Range expression outside loop                |
| **E2009** | Iterators         | For loop only supports ranges                |
| **E2010** | Name Resolution   | Assignment to undeclared variable            |
| **E2011** | Type Checking     | Function argument count mismatch             |
| **E2012** | Type Checking     | Cannot dereference non-reference type        |
| **E2013** | Type Checking     | Type not found                               |
| **E2014** | Type Checking     | Field access error                           |
| **E2015** | Intrinsics        | Intrinsic requires exactly one type argument |
| **E2016** | Intrinsics        | Intrinsic argument must be type name         |
| **E2017** | Intrinsics        | Unknown type in intrinsic                    |
| **E2018** | Type Checking     | Struct construction - invalid target         |
| **E2019** | Type Checking     | Struct construction - missing fields         |
| **E2020** | Type Checking     | Invalid cast                                 |
| **E2021** | Iterator Protocol | Type not iterable (no iter function)         |
| **E2022** | Iterator Protocol | No matching iter(&T) signature               |
| **E2023** | Iterator Protocol | Iterator state missing next function         |
| **E2024** | Iterator Protocol | No matching next(&State) signature           |
| **E2025** | Iterator Protocol | next must return Option type                 |
| **E2026** | Type Checking     | Empty array inference                        |
| **E2027** | Type Checking     | Invalid array index type                     |
| **E2028** | Type Checking     | Non-indexable type                           |
| **E2030** | Pattern Matching  | Match on non-enum type                       |
| **E2031** | Pattern Matching  | Non-exhaustive match                         |
| **E2032** | Pattern Matching  | Match pattern arity mismatch                 |
| **E2034** | Enums             | Duplicate enum variant name                  |
| **E2035** | Enums             | Recursive type without indirection           |
| **E2037** | Pattern Matching  | Unknown enum variant in pattern              |
| **E2102** | Generics          | Conflicting generic type bindings            |

### E3XXX: Code Generation

| Code      | Category          | Description                                  |
|-----------|-------------------|----------------------------------------------|
| **E3001** | Lowering          | Invalid type during struct/null lowering     |
| **E3002** | Lowering          | Field access on unknown type                 |
| **E3003** | Lowering          | Field not found during lowering              |
| **E3004** | Lowering          | Unresolved variable or array type            |
| **E3005** | Lowering          | Non-constant array expression                |
| **E3006** | Lowering          | Break outside loop / array element error     |
| **E3007** | Lowering          | Continue outside loop                        |
| **E3008** | Lowering          | Range type error                             |
| **E3010** | Lowering          | Missing String type / undeclared variable    |
| **E3012** | Lowering          | Invalid address-of operation                 |
| **E3014** | Lowering          | Invalid function during lowering             |
| **E3037** | Lowering          | Enum variant lowering error                  |

---

## Design Philosophy

FLang's error code numbering follows these principles:

1. **Sequential Assignment**: Error codes are assigned sequentially within each category (E2001, E2002, E2003, ...) with
   no gaps or skipped numbers. This prevents arbitrary number choices and ensures consistency.

2. **Phase-Based Categories**: Errors are grouped by compiler phase (E1XXX for frontend, E2XXX for semantics, E3XXX for
   codegen), making it easy to understand where in the compilation pipeline an error occurred.

3. **Self-Documenting**: The error code itself tells you the compiler phase. You don't need a lookup table to know that
   E2XXX errors are semantic analysis errors.

4. **No External Dependencies**: Unlike some compilers that use error codes from other languages, FLang's error codes
   are our own custom scheme designed specifically for our compiler architecture.

5. **Future-Proof**: We reserve ranges for future expansion, ensuring we won't run out of error codes as the language
   grows.

---

## See Also

- `src/FLang.Core/Diagnostic.cs` - Diagnostic infrastructure code
- `src/FLang.Core/DiagnosticPrinter.cs` - Error message formatting
- `src/FLang.Semantics/TypeSolver.cs` - Type checking implementation
- `src/FLang.Semantics/AstLowering.cs` - FIR lowering implementation
