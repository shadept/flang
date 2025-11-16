# FIR Generation Improvement Plan

## Executive Summary

**Goal**: Generate explicit FIR that closely matches LLVM IR semantics, eliminating implicit conversions in the C codegen layer.

**Key Changes**:
1. Introduce `GlobalValue` to represent global symbols (strings, statics) as pointer values
2. Make local struct variables use stack allocation (`alloca`)
3. Explicitly decompose string literal → String struct conversions into individual field stores
4. Load struct values from stack before use

## Current vs Target FIR

### Example Code
```flang
pub fn main() i32 {
    let s: String = "hello"
    println(s)
    return s.len
}
```

### Current FIR (Implicit)
```
define i32 @main() {
entry:
  %s = @str_0  ; Implicit: string constant assigned directly
  call @println(%s)
  %len = field_access %s, len
  return %len
}
```

### Target FIR (Explicit)
```
@LC0 = global [5 x u8] "hello"

define i32 @main() {
entry:
  %s.addr = alloca String                    ; Allocate stack space
  %t_ptr = @LC0                              ; Global is already a pointer
  %ptr_field = getelementptr %s.addr, 0      ; Get &s.ptr
  store %t_ptr, ptr %ptr_field       ; s.ptr = decayed pointer
  %len_field = getelementptr %s.addr, 8      ; Get &s.len
  store 5, ptr %len_field                    ; s.len = 5
  %s_val = load String, ptr %s.addr          ; Load struct value
  call @println(%s_val)                      ; Pass by value
  %len_addr = getelementptr %s.addr, 8       ; Get &s.len again
  %len_val = load i32, ptr %len_addr         ; Load the length
  return %len_val
}
```

## Detailed Implementation Plan

---

## Phase 1: New Value Classes

**File**: `src/FLang.IR/Value.cs`

### 1.1 Add `GlobalValue`

```csharp
/// <summary>
/// Represents a global symbol in memory (static variable, string literal, etc.).
/// CRITICAL: The Type of a GlobalValue is ALWAYS a pointer to its initializer's type.
/// This matches LLVM IR semantics where globals are pointer values.
/// </summary>
public class GlobalValue : Value
{
    public GlobalValue(string name, Value initializer)
    {
        Name = name;  // e.g., "LC0", "LC1"
        Initializer = initializer;

        // Type is a pointer to the initializer's type
        // Example: initializer is [5 x u8] → Type is &[u8; 5]
        Type = new ReferenceType(initializer.Type);
    }

    /// <summary>
    /// The data stored at this global address.
    /// Used by backends to emit .data section.
    /// </summary>
    public Value Initializer { get; set; }
}
```

### 1.2 Add `ArrayConstantValue`

```csharp
/// <summary>
/// Represents a compile-time array constant (e.g., byte array for strings).
/// </summary>
public class ArrayConstantValue : Value
{
    public ArrayConstantValue(byte[] data, FType elementType)
    {
        Data = data;
        Type = new ArrayType(elementType, data.Length);
    }

    public byte[] Data { get; }

    /// <summary>
    /// For string literals, returns the UTF-8 string with null terminator.
    /// </summary>
    public string? StringRepresentation { get; set; }
}
```

### 1.3 Remove `StringConstantValue`

Delete the `StringConstantValue` class - it will be replaced by:
```
GlobalValue(name: "LC0", initializer: ArrayConstantValue([72,101,108,108,111,0], U8))
```

---

## Phase 2: Track Globals in IR

**File**: `src/FLang.IR/Function.cs`

### 2.1 Add Globals Collection

```csharp
public class Function
{
    public Function(string name)
    {
        Name = name;
    }

    public string Name { get; }
    public FType ReturnType { get; set; } = TypeRegistry.I32;
    public List<FunctionParameter> Parameters { get; } = new();
    public List<BasicBlock> BasicBlocks { get; } = new();
    public bool IsForeign { get; set; }

    // NEW: Track global values referenced/created by this function
    public List<GlobalValue> Globals { get; } = new();
}
```

**Note**: Later we may want a Module class that owns globals, but for now Function-level is sufficient.

---

## Phase 3: Update String Literal Lowering

**File**: `src/FLang.Semantics/AstLowering.cs`

### 3.1 Current Implementation (Lines 248-252)
```csharp
case StringLiteralNode stringLiteral:
    var sid = _compilation.AllocateStringId();
    var stringName = $"str_{sid}";
    return new StringConstantValue(stringLiteral.Value, stringName)
        { Type = _typeSolver.GetType(expression) };
```

### 3.2 New Implementation

```csharp
case StringLiteralNode stringLiteral:
{
    var sid = _compilation.AllocateStringId();
    var globalName = $"LC{sid}";  // Use LC0, LC1, LC2... naming

    // Convert string to byte array (UTF-8 + null terminator for C FFI)
    var bytes = System.Text.Encoding.UTF8.GetBytes(stringLiteral.Value);
    var nullTerminated = new byte[bytes.Length + 1];
    Array.Copy(bytes, nullTerminated, bytes.Length);

    // Create array constant initializer
    var arrayConst = new ArrayConstantValue(nullTerminated, TypeRegistry.U8)
    {
        StringRepresentation = stringLiteral.Value
    };

    // Create global (type will be &[u8; N])
    var global = new GlobalValue(globalName, arrayConst);

    // Register in function globals
    _function.Globals.Add(global);

    // Return the global - it's already a pointer!
    return global;
}
```

**Key Change**: Returns a `GlobalValue` typed as `&[u8; N]`, not a `String` struct.

---

## Phase 4: Update Variable Declaration Lowering

**File**: `src/FLang.Semantics/AstLowering.cs`

### 4.1 Current Implementation (Lines 153-170)

```csharp
case VariableDeclarationNode varDecl:
    FType varType = TypeRegistry.I32;
    if (varDecl.Type != null)
        varType = ResolveTypeFromNode(varDecl.Type);
    else if (varDecl.Initializer != null)
        varType = _typeSolver.GetType(varDecl.Initializer) ?? TypeRegistry.I32;

    var local = new LocalValue(varDecl.Name) { Type = varType };
    _locals[varDecl.Name] = local;

    if (varDecl.Initializer != null)
    {
        var value = LowerExpression(varDecl.Initializer);
        _currentBlock.Instructions.Add(new StoreInstruction(varDecl.Name, value, local));
    }
    break;
```

### 4.2 New Implementation

```csharp
case VariableDeclarationNode varDecl:
{
    FType varType = TypeRegistry.I32;
    if (varDecl.Type != null)
        varType = ResolveTypeFromNode(varDecl.Type);
    else if (varDecl.Initializer != null)
        varType = _typeSolver.GetType(varDecl.Initializer) ?? TypeRegistry.I32;

    // Check if this is a struct type
    bool isStruct = varType is StructType structType;

    if (isStruct)
    {
        // Allocate stack space for struct
        var allocaResult = new LocalValue($"{varDecl.Name}.addr")
            { Type = new ReferenceType(varType) };
        var allocaInst = new AllocaInstruction(varType, varType.Size, allocaResult);
        _currentBlock.Instructions.Add(allocaInst);

        // Store the POINTER in locals map
        _locals[varDecl.Name] = allocaResult;

        // Handle initialization
        if (varDecl.Initializer != null)
        {
            var initValue = LowerExpression(varDecl.Initializer);

            // Special case: String literal (GlobalValue) → String struct
            if (varType is StructType st && st.Name == "String" &&
                initValue is GlobalValue global)
            {
                InitializeStringFromGlobal(allocaResult, global, st);
            }
            // General case: struct literal
            else if (initValue.Type is ReferenceType { InnerType: StructType })
            {
                // Copy struct fields from initializer
                CopyStruct(allocaResult, initValue, (StructType)varType);
            }
        }
    }
    else
    {
        // Non-struct: keep existing SSA behavior
        var local = new LocalValue(varDecl.Name) { Type = varType };
        _locals[varDecl.Name] = local;

        if (varDecl.Initializer != null)
        {
            var value = LowerExpression(varDecl.Initializer);
            _currentBlock.Instructions.Add(new StoreInstruction(varDecl.Name, value, local));
        }
    }
    break;
}
```

### 4.3 Add Helper Method: `InitializeStringFromGlobal`

```csharp
private void InitializeStringFromGlobal(Value structPtr, GlobalValue global, StructType stringType)
{
    // Step 1: Store ptr field (offset 0)
    var ptrFieldOffset = stringType.GetFieldOffset("ptr");  // Should be 0
    var ptrFieldAddr = new LocalValue($"t_ptr_addr_{_tempCounter++}")
        { Type = new ReferenceType(new ReferenceType(TypeRegistry.U8)) };
    var gepPtr = new GetElementPtrInstruction(structPtr, new ConstantValue(ptrFieldOffset), ptrFieldAddr);
    _currentBlock.Instructions.Add(gepPtr);

    var storePtr = new StorePointerInstruction(ptrFieldAddr, structPtr);
    _currentBlock.Instructions.Add(storePtr);

    // Step 2: Store len field (offset 8)
    var arrayLen = ((ArrayType)((ReferenceType)global.Type).InnerType).Length - 1; // -1 for null terminator
    var lenFieldOffset = stringType.GetFieldOffset("len");  // Should be 8
    var lenFieldAddr = new LocalValue($"t_len_addr_{_tempCounter++}")
        { Type = new ReferenceType(TypeRegistry.USize) };
    var gepLen = new GetElementPtrInstruction(structPtr, new ConstantValue(lenFieldOffset), lenFieldAddr);
    _currentBlock.Instructions.Add(gepLen);

    var storeLen = new StorePointerInstruction(lenFieldAddr, new ConstantValue(arrayLen));
    _currentBlock.Instructions.Add(storeLen);
}
```

---

## Phase 5: Update Variable Reference Lowering

**File**: `src/FLang.Semantics/AstLowering.cs`

### 5.1 Current Implementation

When a variable is referenced, we return the value from `_locals` directly.

### 5.2 New Implementation

```csharp
case IdentifierExpressionNode identifier:
{
    if (_locals.TryGetValue(identifier.Name, out var localValue))
    {
        // Check if this is a pointer to a struct (alloca'd variable)
        if (localValue.Type is ReferenceType { InnerType: StructType structType })
        {
            // Load the struct value from the stack
            var loadResult = new LocalValue($"{identifier.Name}_val_{_tempCounter++}")
                { Type = structType };
            var loadInst = new LoadInstruction(localValue, loadResult);
            _currentBlock.Instructions.Add(loadInst);
            return loadResult;
        }

        // Non-struct: return SSA value directly
        return localValue;
    }

    throw new Exception($"Undefined variable: {identifier.Name}");
}
```

**Note**: This ensures that when `s` is used in `println(s)`, we emit a `load` instruction.

---

## Phase 6: Update C Code Generator

**File**: `src/FLang.Codegen.C/CCodeGenerator.cs`

### 6.1 Emit Global Declarations

Add new method to emit globals at the top of the C file:

```csharp
private void EmitGlobals()
{
    foreach (var function in _functions)
    {
        foreach (var global in function.Globals)
        {
            if (global.Initializer is ArrayConstantValue arrayConst &&
                arrayConst.StringRepresentation != null)
            {
                // Emit string literal as: const uint8_t* LC0 = (const uint8_t*)"hello";
                _output.AppendLine($"const uint8_t* {global.Name} = (const uint8_t*)\"{EscapeString(arrayConst.StringRepresentation)}\";");
            }
            // Handle other global types as needed
        }
    }
    _output.AppendLine();
}
```

Call this from `Generate()` before emitting functions.

### 6.2 Update `ValueToString`

Add GlobalValue handling:

```csharp
private string ValueToString(Value value)
{
    return value switch
    {
        ConstantValue constant => constant.IntValue.ToString(),

        // NEW: Handle GlobalValue
        GlobalValue global => global.Name,  // Just "LC0", no @ prefix

        // REMOVE: StringConstantValue cases (delete lines 635-636)

        LocalValue local => local.Name,

        _ => throw new Exception($"Unknown value type: {value.GetType().Name}")
    };
}
```

### 6.3 Remove Special StringConstantValue Handling

Delete these lines from `CollectValues` (around line 160):
```csharp
if (value is StringConstantValue strConst && !_stringLiterals.ContainsKey(strConst.Name))
{
    _stringLiterals[strConst.Name] = strConst.StringValue;
    CollectStructType(strConst.Type);
}
```

Globals are now emitted via `EmitGlobals()`.

---

## Phase 7: Update FIR Printer

**File**: `src/FLang.IR/FirPrinter.cs`

### 7.1 Add Global Emission

Update `Print` method:

```csharp
public static string Print(Function function)
{
    var builder = new StringBuilder();

    // NEW: Emit globals first
    foreach (var global in function.Globals)
    {
        builder.AppendLine(PrintGlobal(global));
    }
    if (function.Globals.Count > 0)
        builder.AppendLine();

    // Function signature with type
    var paramTypes = string.Join(", ", function.Parameters.Select(p => TypeToString(p.Type)));
    builder.AppendLine($"define {TypeToString(function.ReturnType)} @{function.Name}({paramTypes}) {{");

    // ... rest unchanged
}
```

### 7.2 Add `PrintGlobal` Method

```csharp
private static string PrintGlobal(GlobalValue global)
{
    var initType = TypeToString(global.Initializer.Type);

    if (global.Initializer is ArrayConstantValue arrayConst &&
        arrayConst.StringRepresentation != null)
    {
        return $"@{global.Name} = global {initType} \"{arrayConst.StringRepresentation}\"";
    }

    return $"@{global.Name} = global {initType} <data>";
}
```

### 7.3 Update `PrintValue` for GlobalValue

Add case to value printing:

```csharp
private static string PrintValue(Value value)
{
    return value switch
    {
        GlobalValue global => $"@{global.Name}",  // @ prefix for FIR
        ConstantValue constant => constant.IntValue.ToString(),
        LocalValue local => $"%{local.Name}",
        _ => value.Name
    };
}
```

---

## Phase 8: Add Array Decay Support

**File**: `src/FLang.IR/Instructions/CastInstruction.cs`

### 8.1 Add CastKind for Array Decay

```csharp
public enum CastKind
{
    // ... existing kinds ...
    ArrayToPointer,  // [N x T]* → T* (decay)
}
```

### 8.2 Update C Codegen for Cast

In `EmitCast`:

```csharp
private void EmitCast(CastInstruction cast)
{
    var sourceExpr = ValueToString(cast.Source);
    var destType = TypeToCType(cast.Result.Type);

    if (cast.Kind == CastKind.ArrayToPointer)
    {
        // Array pointer decays naturally in C
        _output.AppendLine($"    {destType} {cast.Result.Name} = ({destType}){sourceExpr};");
    }
    else
    {
        // Existing cast handling
        _output.AppendLine($"    {destType} {cast.Result.Name} = ({destType}){sourceExpr};");
    }
}
```

---

## Phase 9: Testing Strategy

### 9.1 Verify FIR Output

Create a test program:
```flang
pub fn main() i32 {
    let s: String = "hello"
    println(s)
    return s.len
}
```

Expected FIR:
```
@LC0 = global [6 x u8] "hello"

define i32 @main() {
entry:
  %s.addr = alloca String ; 16 bytes
  %t_ptr_0 = cast &[u8; 6] @LC0 to &u8
  %t_ptr_addr_1 = getelementptr &String %s.addr, 0
  store &u8 %t_ptr_0, ptr %t_ptr_addr_1
  %t_len_addr_2 = getelementptr &String %s.addr, 8
  store 5, ptr %t_len_addr_2
  %s_val_3 = load String, ptr %s.addr
  call @println(String %s_val_3)
  %len_addr_4 = getelementptr &String %s.addr, 8
  %len_val_5 = load i32, ptr %len_addr_4
  return %len_val_5
}
```

### 9.2 Run Test Suite

```powershell
.\build.ps1
.\build-all-tests.ps1
```

### 9.3 Check C Output Quality

Expected C code should match the target example provided, with:
- `const uint8_t* LC0 = ...` at file scope
- `FLangString s;` local variable
- Explicit field assignments: `s.ptr = ...`, `s.len = ...`

---

## Migration Notes

### Breaking Changes
- `StringConstantValue` removed - update any code that pattern matches on it
- `_locals` map now stores pointers for struct types, not values

### Compatibility
- Non-struct variables keep SSA behavior (no alloca)
- Existing tests should work after FIR/codegen updates

### Future Work
- Generalize this pattern for all slice types (not just String)
- Add proper Module class to own globals
- Support static variables and const globals

---

## Summary

This plan transforms FIR generation from implicit (relying on backend hacks) to explicit (matching LLVM IR semantics). The key insight is that **globals are pointers**, and struct initialization should be decomposed into individual memory operations visible in the IR.