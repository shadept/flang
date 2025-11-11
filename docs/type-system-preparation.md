# Type System Preparation for Future Milestones

## Overview

This document describes the infrastructure added to prepare the FLang type system for upcoming milestones (Milestone 6: Pointers & References, and Milestone 11+: Generics).

## What Was Added

### 1. Lexer & Token Support

Added new tokens to support complex type syntax:

- `Ampersand` (`&`) - for reference types
- `Question` (`?`) - for nullable/optional types
- `OpenBracket` (`[`) - for generic type arguments
- `CloseBracket` (`]`) - for generic type arguments

### 2. AST Type Nodes

Created new TypeNode subclasses in `src/FLang.Frontend/Ast/Types/TypeNode.cs`:

```csharp
// Reference types: &T
public class ReferenceTypeNode : TypeNode
{
    public TypeNode InnerType { get; }
}

// Nullable types: T? (sugar for Option[T])
public class NullableTypeNode : TypeNode
{
    public TypeNode InnerType { get; }
}

// Generic types: List[T], Dict[K, V]
public class GenericTypeNode : TypeNode
{
    public string Name { get; }
    public IReadOnlyList<TypeNode> TypeArguments { get; }
}
```

### 3. Type Parser

Added comprehensive type parsing in `src/FLang.Frontend/Parser.cs`:

```
Grammar:
  type := prefix_type postfix*
  prefix_type := '&' prefix_type | primary_type
  primary_type := identifier generic_args?
  generic_args := '[' type (',' type)* ']'
  postfix := '?'
```

This allows parsing complex type expressions like:

- `i32` - simple types (already working)
- `&i32` - reference to i32
- `i32?` - nullable i32
- `&i32?` - nullable reference to i32
- `List[i32]` - generic list of i32
- `&List[i32]` - reference to list
- `List[i32]?` - nullable list
- `&List[i32]?` - nullable reference to generic list
- `Dict[String, i32]` - multi-parameter generics

### 4. Type System Classes

Added placeholder types in `src/FLang.Semantics/Type.cs`:

```csharp
// Reference type: &T
public class ReferenceType : Type
{
    public Type InnerType { get; }
}

// Optional/nullable type: T? or Option[T]
public class OptionType : Type
{
    public Type InnerType { get; }
}

// Generic type: List[T], Dict[K,V]
public class GenericType : Type
{
    public string BaseName { get; }
    public IReadOnlyList<Type> TypeArguments { get; }
}
```

### 5. Type Resolver Updates

Updated both `TypeSolver` and `AstLowering` to handle the new type nodes:

```csharp
private Type? ResolveTypeNode(TypeNode? typeNode)
{
    switch (typeNode)
    {
        case NamedTypeNode namedType: // ...
        case ReferenceTypeNode referenceType: // ...
        case NullableTypeNode nullableType: // ...
        case GenericTypeNode genericType: // ...
    }
}
```

## What This Enables

### Immediate Benefits

- **Clean Architecture**: Type parsing is now centralized in `ParseType()` method
- **Forward Compatibility**: Can parse future type syntax without parser changes
- **Type Safety**: All type constructs have proper AST representation

### For Milestone 6 (Pointers & References)

- Syntax already parses: `&T`, `&T?`
- Types already have `ReferenceType` representation
- Just need to implement:
  - Address-of operator (`&variable`)
  - Dereference semantics
  - Null checking for `&T?`
  - C codegen for pointers

### For Future Milestones (Generics)

- Syntax already parses: `List[T]`, `Dict[K, V]`
- Types already have `GenericType` representation
- Just need to implement:
  - Type parameter binding (`$T`)
  - Monomorphization/code generation
  - Generic constraints

## Examples

Current code (Milestone 5) uses simple types:

```flang
pub fn add(a: i32, b: i32) i32 {
    return a + b
}
```

Future code (Milestone 6+) will support:

```flang
// Reference types
pub fn swap(a: &i32, b: &i32) {
    let temp: i32 = *a
    *a = *b
    *b = temp
}

// Nullable types
pub fn find(arr: &i32[], value: i32) i32? {
    // returns Some(index) or None
}

// Generics
pub fn identity(x: $T) T {
    return x
}

pub fn map(list: List[$T], f: fn($T) $U) List[$U] {
    // ...
}
```

## Testing

All existing tests (15/15) pass with no regressions. The new type parsing is exercised through:

- Function parameter types
- Function return types
- Variable type annotations

## Next Steps

When implementing Milestone 6 or later milestones:

1. **For References (`&T`)**:

   - Add address-of operator to expression parser
   - Implement reference semantics in TypeSolver
   - Add pointer operations to FIR
   - Update C codegen to use pointer syntax

2. **For Nullable (`T?`)**:

   - Implement Option[T] type in stdlib
   - Add pattern matching or null checking syntax
   - Implement null coalescing (`??`)
   - Implement null propagation (`?`)

3. **For Generics (`List[T]`)**:
   - Implement type parameter syntax (`$T`)
   - Add generic constraints checking
   - Implement monomorphization pass
   - Update codegen for specialized types

## Files Modified

- `src/FLang.Frontend/TokenKind.cs` - Added tokens
- `src/FLang.Frontend/Lexer.cs` - Added token recognition
- `src/FLang.Frontend/Ast/Types/TypeNode.cs` - Added type AST nodes
- `src/FLang.Frontend/Parser.cs` - Added `ParseType()` and `ParsePrimaryType()`
- `src/FLang.Semantics/Type.cs` - Added placeholder type classes
- `src/FLang.Semantics/TypeSolver.cs` - Updated type resolution
- `src/FLang.Semantics/AstLowering.cs` - Updated type resolution

## Status

✅ **Type Parsing Infrastructure**: Complete and tested
⏳ **Reference Semantics**: Ready for Milestone 6 implementation
⏳ **Generic Semantics**: Ready for Milestone 11+ implementation
