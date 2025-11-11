# FLang Compiler Error Codes

This document provides a comprehensive reference for all compiler error codes used in FLang. Error codes follow the pattern `EXXXX` where `XXXX` is a four-digit number indicating the compiler phase and error type.

## Error Code Numbering Scheme

FLang uses a custom sequential numbering system organized by compiler phase:

- **E1XXX**: Frontend errors (lexing, parsing, syntax)
- **E2XXX**: Semantic analysis errors (type checking, name resolution, control flow)
- **E3XXX**: Code generation errors (FIR lowering, C code generation)

Within each category, error codes are assigned sequentially starting from E1001, E2001, E3001, etc. This ensures no gaps and no bias in numbering.

---

## E1XXX: Frontend Errors (Lexing & Parsing)

_Currently no errors in this category. Reserved for future parsing errors._

---

## E2XXX: Semantic Analysis Errors

### E2001: Cannot Infer Type

**Category**: Type Inference
**Severity**: Error

#### Description

The compiler cannot infer the type of a variable because it has a compile-time type (`comptime_int` or `comptime_float`) that must be resolved to a concrete type. Type annotations are required.

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

A value of one type was provided where a different type was expected. This is the most common type error and can occur in many contexts:

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

A variable was declared twice in the same scope with the same name. Each variable name can only be declared once per scope.

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

A `break` statement was used outside of a loop context. The `break` statement can only be used inside `for` loops to exit the loop early.

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

A `continue` statement was used outside of a loop context. The `continue` statement can only be used inside `for` loops to skip to the next iteration.

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

A range expression (`a..b`) was used outside of a `for` loop context. Range expressions are currently only supported as the iterable in `for` loops.

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

A `for` loop attempted to iterate over a non-range expression. Currently, FLang only supports range expressions (`a..b`) as the iterable in `for` loops. Support for iterating over other types (arrays, slices, custom iterators) will be added in future milestones.

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

An assignment was attempted to a variable that has not been declared with `let`. In FLang, variables must be declared before they can be assigned to.

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

A function was called with the wrong number of arguments. The number of arguments provided must match the number of parameters declared in the function signature.

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

## E3XXX: Code Generation Errors

_Currently no errors in this category. Reserved for future codegen errors._

---

## Summary Table

| Code      | Category        | Description                          |
| --------- | --------------- | ------------------------------------ |
| **E2001** | Type Inference  | Cannot infer type (needs annotation) |
| **E2002** | Type Checking   | Mismatched types                     |
| **E2003** | Name Resolution | Cannot find type in scope            |
| **E2004** | Name Resolution | Cannot find value in scope           |
| **E2005** | Name Resolution | Variable already declared            |
| **E2006** | Control Flow    | Break statement outside loop         |
| **E2007** | Control Flow    | Continue statement outside loop      |
| **E2008** | Control Flow    | Range expression outside loop        |
| **E2009** | Iterators       | For loop only supports ranges        |
| **E2010** | Name Resolution | Assignment to undeclared variable    |
| **E2011** | Type Checking   | Function argument count mismatch     |

---

## Future Error Codes (Planned)

As FLang development continues, additional error codes will be added:

### E1XXX - Frontend

- E1001: Unexpected token
- E1002: Unterminated string literal
- E1003: Invalid number format
- E1004: Invalid character
- And more...

### E2XXX - Semantic Analysis

- E2012: Borrow checking violation
- E2013: Lifetime error
- E2014: Trait bound not satisfied
- And more...

### E3XXX - Code Generation

- E3001: Cannot generate code for expression
- E3002: Unsupported target architecture
- E3003: Code generation internal error
- And more...

---

## Design Philosophy

FLang's error code numbering follows these principles:

1. **Sequential Assignment**: Error codes are assigned sequentially within each category (E2001, E2002, E2003, ...) with no gaps or skipped numbers. This prevents arbitrary number choices and ensures consistency.

2. **Phase-Based Categories**: Errors are grouped by compiler phase (E1XXX for frontend, E2XXX for semantics, E3XXX for codegen), making it easy to understand where in the compilation pipeline an error occurred.

3. **Self-Documenting**: The error code itself tells you the compiler phase. You don't need a lookup table to know that E2XXX errors are semantic analysis errors.

4. **No External Dependencies**: Unlike some compilers that use error codes from other languages, FLang's error codes are our own custom scheme designed specifically for our compiler architecture.

5. **Future-Proof**: We reserve ranges for future expansion, ensuring we won't run out of error codes as the language grows.

---

## See Also

- `src/FLang.Core/Diagnostic.cs` - Diagnostic infrastructure code
- `src/FLang.Core/DiagnosticPrinter.cs` - Error message formatting
- `src/FLang.Semantics/TypeSolver.cs` - Type checking implementation
- `src/FLang.Semantics/AstLowering.cs` - FIR lowering implementation
