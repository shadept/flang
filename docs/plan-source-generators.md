# Source Generators

## Overview

Source generators are compile-time templates that produce FLang source code. They give programmers the ability to implement missing features as user-defined directives (`#name`). Think Handlebars/Mustache for FLang — structured templates with access to type introspection, expanding into valid FLang source that gets parsed and typechecked normally.

**Key properties:**
- Templates produce **source text**, not AST — output must be valid FLang
- Type introspection uses the **same `TypeInfo`/`FieldInfo`** as runtime RTTI
- Expansion happens **mid-compilation** (between collect and check phases)
- **No new runtime/interpreter** — just a thin template engine over existing compiler data
- User-defined, not compiler-magic — anyone can write `#define(my_thing, ...)`

---

## Syntax

### Generator Definition

```
#define(name, Param1: Kind, Param2: Kind, ...) {
  // template body — FLang source with interpolation directives
}
```

**Parameter kinds:**
- `Ident` — a bare identifier (e.g., `Writer`)
- `Type` — a type expression, including anonymous `struct { ... }` or `enum { ... }`

**Variadic parameters:**
- `..Param: Kind` — collects all remaining arguments into a list
- Only the last parameter may be variadic
- At most one variadic parameter per definition
- Example: `#define(derive, T: Type, ..Traits: Ident)`

### Generator Invocation

```
#name(arg1, arg2, ...)
```

Top-level statement. Triggers template expansion with the given arguments.

### Template Directives

| Directive | Description |
|---|---|
| `#(expr)` | Interpolation — evaluates `expr`, emits as source text |
| `#for var in collection { ... }` | Iteration with named binding |
| `#if condition { ... } #else { ... }` | Conditional emission |
| `type_of(string_expr)` | Compile-time type lookup by name, returns `NominalType` |

### Expression Language

Template expressions use FLang semantics:
- Dot access: `T.name`, `field.type_info`, `fn_type.return_type`
- Member access: `.name`, `.fields`, `.params`, `.return_type`, `.kind`, `.len`
- Indexing: `list[0]`, slicing: `list[1..]`
- String concat: `Impl.name + "_" + Iface.name`
- Comparison: `==`, `!=`, `<`, `>`, `<=`, `>=`
- Built-in functions: `type_of(name)`, `lower(s)`, `snake_case(s)`, `pascal_case(s)`

### Anonymous Type Expressions

`struct { ... }` and `enum { ... }` can appear inline as type expressions, optionally with generic type parameters via `struct(T) { ... }`:

```
#interface(Writer, struct {
  write: fn(data: u8[]) usize
  flush: fn() bool
})

// With generic type parameters:
#interface(Reader, struct(T) {
  read: fn(buf: T[]) usize
})
```

These are parsed as anonymous type definitions and passed to generators as `Type` parameters. Generic type parameters are accessible via `Spec.type_params` in template expressions.

---

## Type Introspection

The template engine uses the **same RTTI model** as runtime (`core/rtti.f`), extended with function type info:

```
TypeInfo {
  name: String
  size: u8
  align: u8
  kind: TypeKind        // Primitive, Array, Struct, Enum, Function
  type_params: String[]
  type_args: &TypeInfo[]
  fields: FieldInfo[]
  params: ParamInfo[]   // NEW — non-empty when kind == Function
  return_type: &TypeInfo // NEW
}

FieldInfo {
  name: String
  offset: usize
  type: &TypeInfo
}

ParamInfo {              // NEW
  name: String
  type: &TypeInfo
}
```

The `TypeKind.Function` variant and `ParamInfo` struct are new additions, useful both for generators and runtime reflection.

---

## Compilation Pipeline

### Modified Type Checker Phases

```
loop {
  collect  — gather all declarations + pending #invocations
  expand   — resolve TypeInfo for expansion inputs,
             expand templates, parse generated source,
             inject new AST nodes
  if (no new expansions produced) break
}
check    — full typecheck on everything (original + generated)
```

The loop handles generators that produce code containing other `#invocations`. Each iteration:
1. **Collect** picks up any new declarations (including from previous expansions)
2. **Expand** finds pending invocations whose type dependencies are resolved, expands them
3. If an iteration produces nothing new → done. If dependencies can't be resolved → cycle error.

### Error Handling

- **Syntax error in generated source:** caught during parse of expanded text. Report error, abort. Show "expanded from `#name` at file:line" hint.
- **Type error in generated source:** caught during check phase, same as hand-written code. Diagnostic includes "expanded from `#name` at file:line" hint pointing to the invocation site and the template definition.

### Debug Support

- `--dump-expanded` CLI flag prints all generated source before typechecking
- Generated code annotated with source location of the `#invocation` for debugger mapping

---

## Motivating Example: Interfaces

### User Code (before expansion)

```
#interface(Writer, struct {
  write: fn(data: u8[]) usize
  flush: fn() bool
})

struct StringBuilder {
  buf: u8[]
  len: usize
}

fn write(self: &StringBuilder, data: u8[]) usize {
  // append data to buf
  return data.len
}

fn flush(self: &StringBuilder) bool {
  return true
}

#implement(StringBuilder, Writer)

fn main() {
  let sb = StringBuilder { buf: [], len: 0 }
  let w = sb.writer()
  w.write("hello")
  w.flush()
}
```

### Generated Code (after expansion)

From `#interface(Writer, struct { ... })`:

```
struct WriterVtable {
  write: fn(ctx: &u8, data: u8[]) usize
  flush: fn(ctx: &u8) bool
}

struct Writer {
  _ctx: &u8
  _vtable: &WriterVtable
}

fn write(self: &Writer, data: u8[]) usize {
  return self._vtable.write(self._ctx, data)
}

fn flush(self: &Writer) bool {
  return self._vtable.flush(self._ctx)
}
```

From `#implement(StringBuilder, Writer)`:

```
fn __StringBuilder_Writer_write(ctx: &u8, data: u8[]) usize {
  let self = ctx as &StringBuilder
  return self.write(data)
}

fn __StringBuilder_Writer_flush(ctx: &u8) bool {
  let self = ctx as &StringBuilder
  return self.flush()
}

const __StringBuilder_Writer_vtable = WriterVtable {
  write: __StringBuilder_Writer_write
  flush: __StringBuilder_Writer_flush
}

fn writer(self: &StringBuilder) Writer {
  return Writer { _ctx: self as &u8, _vtable: &__StringBuilder_Writer_vtable }
}
```

### Generator Definitions

See `stdlib/std/interface.f` for the actual `#interface`/`#implement` definitions. Key syntax:

```
#define(interface, Name: Ident, Spec: Type) {
    type #(Name)Vtable = struct {
        #for method in Spec.fields {
            #(method.name): fn(ctx: &u8, #for p in method.type_info.params { #(p.name): #(p.type_info.name), }) #(method.type_info.return_type.name)
        }
    }
    // ... vtable struct, dispatch methods
}

#define(implement, Impl: Ident, Iface: Ident) {
    // ... thunk functions, vtable const, conversion method
}
```

See `stdlib/std/derive.f` for `#derive`:

```
#define(derive, T: Type, ..Traits: Ident) {
    #for Trait in Traits {
        #if Trait == "eq" {
            pub fn op_eq(a: #(T.name), b: #(T.name)) bool {
                #for field in type_of(T.name).fields {
                    if a.#(field.name) != b.#(field.name) { return false }
                }
                return true
            }
        } #else #if Trait == "clone" {
            // ... field-by-field copy
        } #else #if Trait == "debug" {
            // ... StringBuilder format
        }
    }
}
```

See `stdlib/std/enum_utils.f` for `#enum_utils`:

```
#define(enum_utils, E: Type) {
    pub fn to_string(self: #(E.name)) String {
        return self match {
            #for v in type_of(E.name).fields {
                #(E.name).#(v.name) => #("\"" + v.name + "\""),
            }
        }
    }
    // ... from_string
}
```

---

## Other Use Cases

### Derive (auto-generated common methods) ✅ DONE

```
#derive(Vec2, eq, clone, debug)  // all three in one call via variadic params

// Generates:
//   fn op_eq(a: Vec2, b: Vec2) bool      — field-by-field equality
//   fn clone(self: &Vec2) Vec2            — field-by-field copy
//   fn format(self: &Vec2, sb: &StringBuilder, spec: String) — debug format
```

### Serialization

```
#serialize(MyConfig, json)
#serialize(MyConfig, yaml)

// generates: fn to_json(self: &MyConfig, writer: Writer), fn from_json(data: String, reader: Reader)
```

### Builder Pattern

```
#builder(HttpRequest)

// generates: HttpRequestBuilder struct + fluent setter methods + build()
```

### Enum Utilities ✅ DONE

```
#enum_utils(Color)

// Generates:
//   fn to_string(self: Color) String      — match-based variant name
//   fn from_string(s: String) Color?      — if-chain lookup by name
```

### Bitflags

```
#bitflags(Permissions, enum {
  Read = 1
  Write = 2
  Execute = 4
})

// generates: struct Permissions { value: u32 } + has/set/unset + constants
```

### State Machine

```
#state_machine(Connection, struct {
  Idle:        struct { connect: Connected }
  Connected:   struct { send: Connected, disconnect: Idle, error: Failed }
  Failed:      struct { retry: Idle }
})

// generates: enum + validated transition functions
```

### Visitor Pattern

```
#visitor(AstNode, struct {
  Literal: LiteralNode
  Binary:  BinaryNode
  Unary:   UnaryNode
})

// generates: visitor struct + accept method + dispatch
```

---

## Implementation Plan

### Phase 0: Unified Type Declaration Syntax ✅ DONE

**Goal:** Replace `struct Name { ... }` and `enum Name { ... }` with `type Name = struct { ... }` and `type Name = enum { ... }`. One canonical way to declare named types. Generic type parameters live on the `struct`/`enum` keyword, not on the name.

**Syntax:**
```
type Vec2 = struct { x: i32, y: i32 }
type Color = enum { Red, Green, Blue }
type Option = struct(T) { has_value: bool, value: T }
type Result = enum(T, E) { Ok(T), Err(E) }
```

**Changes:**
- Parser: `type Name = struct(T) { ... }` parses type params after `struct`/`enum` keyword
- Parser: `struct Name { ... }` / `enum Name { ... }` is a hard error (E1050/E1051)
- Parser: `type Name(T) = struct { ... }` (params on name) is a hard error (E1052)
- `type Name = ...` is purely naming; generics belong on `struct`/`enum`
- This makes named and anonymous usage consistent: `struct(T) { ... }` works in both contexts

**Test:** `type Foo = struct { x: i32, y: i32 }` compiles. Generic: `type Pair = struct(T) { a: T, b: T }` works with monomorphization.

---

### Phase 1: Anonymous Type Expressions ✅ DONE

**Goal:** `struct { ... }` and `enum { ... }` usable as inline type expressions (unnamed), including with generic type parameters via `struct(T) { ... }`.

**Changes:**
- Parser: `struct(T, U) { ... }` / `enum(T) { ... }` in expression/argument position (not just after `type Name =`)
- Type parameters on anonymous structs use the same `(T, U, ...)` syntax as named types
- Type checker: register anonymous types with compiler-generated names
- `TypeInfo.type_params` populated from anonymous struct type parameters
- These are the building blocks for generator arguments

**Test:** `#interface(Reader, struct(T) { read: fn(buf: T[]) usize })` parses the anonymous struct with type param `T` as a generator argument (expansion not yet wired).

---

### Phase 2: RTTI Extension for Function Types ✅ DONE

**Goal:** `TypeInfo` exposes function parameters and return type.

**Changes:**
- Add `TypeKind.Function` variant
- Add `ParamInfo` struct to `core/rtti.f`
- Add `params: ParamInfo[]` and `return_type: &TypeInfo` to `TypeInfo`
- Update `HmAstLowering.EnsureTypeTableExists` to populate function type info

**Test:** Runtime `type_of(fn(i32) bool)` returns `TypeInfo` with correct `params` and `return_type`.

---

### Phase 3: `#define` Parsing & Storage ✅ DONE

**Goal:** Parse generator definitions and store templates.

**Changes:**
- Lexer: `#define` as keyword/directive (alongside `#foreign`, `#inline`)
- Parser: parse `#define(name, params...) { body }` — store body as raw token stream
- AST: `SourceGeneratorDefinitionNode { Name, Parameters, BodyTokens }`
- Definitions registered in a module-level generator registry

**Test:** `#define(foo, T: Type) { struct #(T.name)Copy { } }` parses without error. Verify AST node created with correct parameter list and token body.

---

### Phase 4: `#invocation` Parsing ✅ DONE

**Goal:** Parse generator call sites as pending expansion nodes.

**Changes:**
- Parser: `#name(args...)` at top level → `SourceGeneratorInvocationNode`
- Arguments can be: identifiers, type expressions (including `struct { ... }`), literals
- Invocation nodes stored in AST alongside regular declarations

**Test:** `#foo(MyType, struct { x: i32 })` parses into correct invocation node with two arguments.

---

### Phase 5: Template Engine ✅ DONE

**Goal:** Expand templates into FLang source text.

**Changes:**
- New `TemplateEngine` class in `FLang.Semantics`
- Evaluates `#(expr)`: dot access on TypeInfo/FieldInfo, string concat, slicing
- Evaluates `#each(collection) { body }`: iteration with `it` binding
- Evaluates `#if(condition) { body }`: conditional emission
- Evaluates `#join(sep, items)`: string joining, composable with `#each`
- Built-in functions: `typeof(string)`, `lower(string)`
- Output: string of FLang source code

**Test:** Given a TypeInfo for `struct Foo { x: i32, y: i32 }` and a template `#each(T.fields) { let #(it.name): #(it.type.name) }`, engine produces `let x: i32\nlet y: i32`.

---

### Phase 6: Collect/Expand Loop ✅ DONE

**Goal:** Wire template expansion into the type checker pipeline.

**Changes:**
- Type checker gains new phase between collect and check:
  ```
  loop {
    collect
    expand (resolve types → expand templates → parse → inject AST)
    if (nothing new) break
  }
  check
  ```
- Expansion: for each pending invocation, check if all type dependencies are resolved
- If resolved: expand template, parse result, splice into AST, mark as expanded
- Cycle detection: if an iteration resolves nothing → compile error listing unresolved generators
- Generated AST nodes tagged with expansion source location

**Test:**
1. `#interface(Writer, struct { write: fn(data: u8[]) usize })` expands, generates `WriterVtable` and `Writer` structs, dispatch method. Code using `Writer` type-checks.
2. `#implement(StringBuilder, Writer)` expands in a subsequent iteration (depends on `WriterVtable` from step 1).
3. Circular dependency between two generators produces a clear error.

---

### Phase 7: Diagnostics

**Goal:** Errors in generated code are traceable.

**Changes:**
- `SourceSpan` on generated AST nodes carries both the generated location and the expansion origin
- Diagnostic printer shows "expanded from `#name` at file:line" hint
- `--dump-expanded` CLI flag dumps all generated source to stderr before check phase

**Test:** A type error inside generated code shows the error location AND "expanded from #interface at main.f:5".

---

### Phase 8: Stdlib Generators ✅ DONE

**Goal:** Ship useful generators in the standard library.

**Generators implemented:**
1. `#interface` + `#implement` — vtable-based interfaces (`stdlib/std/interface.f`)
2. `#derive(Type, eq)` — field-by-field equality (`stdlib/std/derive.f`)
3. `#derive(Type, clone)` — field-by-field copy (`stdlib/std/derive.f`)
4. `#derive(Type, debug)` — debug string via StringBuilder (`stdlib/std/derive.f`)
5. `#enum_utils(Enum)` — to_string, from_string (`stdlib/std/enum_utils.f`)

`#derive` uses variadic parameters: `#define(derive, T: Type, ..Traits: Ident)` — multiple traits in one call.

**Test:** Each generator has end-to-end tests in `tests/.../source_generators/`.

---

## Design Decisions

1. **Where do `#define`s live?** Some directives are compiler-provided because they tie closely to how the language works or a particular compilation step: `#foreign`, `#define`, `#inline`. Everything else is user-defined in regular `.f` files and importable like any other declaration.
2. **Anonymous type expressions are general.** `struct { ... }` is a valid type expression anywhere — generator arguments, `type` aliases, variable types, etc. No special-casing.
3. **Error recovery uses placeholder source.** If a generator expansion fails, inject placeholder/stub declarations (similar to how the typechecker introduces type variables for unresolved generics) so that remaining compilation can proceed and report further errors rather than cascading.
4. **Naming collisions are the author's responsibility.** Generated code is injected as-if the user wrote it. No automatic scoping or mangling. Users are adults in control.
5. **Visibility is controlled by the template.** If a generated declaration should be `pub`, the generator author writes `pub` in the template. Generated source is interpreted exactly as if it were written in the original source file.
