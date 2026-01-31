using FLang.Core;
using FType = FLang.Core.TypeBase;
using FLang.Frontend.Ast;
using FLang.Frontend.Ast.Declarations;
using FLang.Frontend.Ast.Expressions;
using FLang.Frontend.Ast.Statements;
using FLang.IR;
using FLang.IR.Instructions;
using Microsoft.Extensions.Logging;

namespace FLang.Semantics;

public class AstLowering
{
    private readonly Compilation _compilation;
    private readonly List<BasicBlock> _allBlocks = [];
    private readonly List<Diagnostic> _diagnostics = [];
    private readonly Dictionary<string, Value> _locals = [];
    private readonly HashSet<string> _parameters = [];
    private readonly Stack<LoopContext> _loopStack = new();
    private readonly Stack<List<ExpressionNode>> _deferStack = new();
    private readonly ILogger<AstLowering> _logger;
    private int _blockCounter;
    private BasicBlock _currentBlock = null!;
    private Function _currentFunction = null!;
    private FunctionDeclarationNode _currentFunctionNode = null!;
    private int _tempCounter;

    // Track variable shadowing: maps source name to a counter for generating unique IR names
    private readonly Dictionary<string, int> _shadowCounter = [];

    // Track type literal indices for the global type table
    private readonly Dictionary<FType, int> _typeTableIndices = [];
    private GlobalValue? _typeTableGlobal = null;

    private AstLowering(Compilation compilation, ILogger<AstLowering> logger)
    {
        _compilation = compilation;
        _logger = logger;
    }

    public IReadOnlyList<Diagnostic> Diagnostics => _diagnostics;

    public static (Function Function, IReadOnlyList<Diagnostic> Diagnostics) Lower(FunctionDeclarationNode functionNode,
        Compilation compilation, TypeChecker typeSolver, ILogger<AstLowering> logger)
    {
        // Note: typeSolver parameter kept for API compatibility but is no longer used
        // All type information should be pre-resolved on AST nodes during type checking
        var lowering = new AstLowering(compilation, logger);
        var function = lowering.LowerFunction(functionNode);
        return (function, lowering.Diagnostics);
    }

    /// <summary>
    /// Lower a test declaration to a void function.
    /// </summary>
    public static (Function Function, IReadOnlyList<Diagnostic> Diagnostics) LowerTest(
        FLang.Frontend.Ast.Declarations.TestDeclarationNode testNode,
        Compilation compilation, TypeChecker typeSolver, ILogger<AstLowering> logger)
    {
        var lowering = new AstLowering(compilation, logger);
        var function = lowering.LowerTestDeclaration(testNode);
        return (function, lowering.Diagnostics);
    }

    /// <summary>
    /// Lower global constants from a module and store them in Compilation.LoweredGlobalConstants.
    /// Must be called before lowering functions that reference these constants.
    /// </summary>
    public static IReadOnlyList<Diagnostic> LowerGlobalConstants(
        ModuleNode module,
        Compilation compilation,
        ILogger<AstLowering> logger)
    {
        var lowering = new AstLowering(compilation, logger);
        lowering.LowerModuleGlobalConstants(module);
        return lowering.Diagnostics;
    }

    private void LowerModuleGlobalConstants(ModuleNode module)
    {
        foreach (var globalConst in module.GlobalConstants)
        {
            var constType = globalConst.ResolvedType ??
                throw new InvalidOperationException($"Global constant '{globalConst.Name}' has no resolved type");

            if (globalConst.Initializer == null)
            {
                _diagnostics.Add(Diagnostic.Error(
                    $"global constant `{globalConst.Name}` has no initializer",
                    globalConst.Span,
                    "global constants must be initialized",
                    "E3007"
                ));
                continue;
            }

            // Lower the initializer expression to get its value
            // For global constants, we need to evaluate compile-time constant expressions
            var initValue = LowerGlobalConstantInitializer(globalConst.Initializer, constType, globalConst.Name);
            if (initValue != null)
            {
                _compilation.LoweredGlobalConstants[globalConst.Name] = initValue;
            }
        }
    }

    private Value? LowerGlobalConstantInitializer(ExpressionNode initializer, FType constType, string constName)
    {
        // Unwrap implicit coercion nodes - we use the target type for the final value
        if (initializer is ImplicitCoercionNode coercion)
        {
            return LowerGlobalConstantInitializer(coercion.Inner, constType, constName);
        }

        // Handle named struct construction (e.g., AllocatorVTable { alloc = fn, ... })
        if (initializer is StructConstructionExpressionNode structConstruction && constType is StructType st)
        {
            var fieldValues = new Dictionary<string, Value>();
            foreach (var field in structConstruction.Fields)
            {
                var fieldType = st.Fields.FirstOrDefault(f => f.Name == field.FieldName).Type;
                if (fieldType == null) continue;

                var fieldValue = LowerGlobalConstantInitializer(field.Value, fieldType, $"{constName}.{field.FieldName}");
                if (fieldValue != null)
                {
                    fieldValues[field.FieldName] = fieldValue;
                }
            }

            var structConst = new StructConstantValue(st, fieldValues);
            var global = new GlobalValue($"__global_{constName}", structConst);
            return global;
        }

        // Handle anonymous struct construction (e.g., .{ field = value, ... })
        if (initializer is AnonymousStructExpressionNode anonStruct && constType is StructType anonSt)
        {
            var fieldValues = new Dictionary<string, Value>();
            foreach (var field in anonStruct.Fields)
            {
                var fieldType = anonSt.Fields.FirstOrDefault(f => f.Name == field.FieldName).Type;
                if (fieldType == null) continue;

                var fieldValue = LowerGlobalConstantInitializer(field.Value, fieldType, $"{constName}.{field.FieldName}");
                if (fieldValue != null)
                {
                    fieldValues[field.FieldName] = fieldValue;
                }
            }

            var structConst = new StructConstantValue(anonSt, fieldValues);
            var global = new GlobalValue($"__global_{constName}", structConst);
            return global;
        }

        // Handle integer literals
        if (initializer is IntegerLiteralNode intLit)
        {
            return new ConstantValue(intLit.Value) { Type = constType };
        }

        // Handle boolean literals
        if (initializer is BooleanLiteralNode boolLit)
        {
            return new ConstantValue(boolLit.Value ? 1 : 0) { Type = TypeRegistry.Bool };
        }

        // Handle identifier references (e.g., referencing other global constants or functions)
        if (initializer is IdentifierExpressionNode ident)
        {
            // Check if it's a function reference
            if (ident.Type is FunctionType && ident.ResolvedFunctionTarget != null)
            {
                return new FunctionReferenceValue(ident.ResolvedFunctionTarget.Name, ident.Type);
            }

            // Check if it's another global constant
            if (_compilation.LoweredGlobalConstants.TryGetValue(ident.Name, out var existingGlobal))
            {
                return existingGlobal as Value;
            }

            _diagnostics.Add(Diagnostic.Error(
                $"global constant initializer cannot reference local variable `{ident.Name}`",
                initializer.Span,
                "global constant initializers must be compile-time evaluable",
                "E3008"
            ));
            return null;
        }

        // Handle address-of expressions (e.g., &global_allocator_state)
        if (initializer is AddressOfExpressionNode addressOf)
        {
            // The inner expression must be a reference to another global constant
            var innerValue = LowerGlobalConstantInitializer(addressOf.Target, addressOf.Target.Type ?? constType, constName);
            if (innerValue is GlobalValue)
            {
                // GlobalValue already has pointer type - return it directly
                return innerValue;
            }

            if (innerValue != null)
            {
                // Wrap non-global values in a GlobalValue to get a pointer
                var global = new GlobalValue($"__global_{constName}_addr", innerValue);
                return global;
            }

            return null;
        }

        // Handle cast expressions (e.g., &x as &u8)
        if (initializer is CastExpressionNode cast)
        {
            var innerValue = LowerGlobalConstantInitializer(cast.Expression, cast.Expression.Type ?? constType, constName);
            if (innerValue != null)
            {
                // For constant initializers, casts are type-only reinterpretations
                innerValue.Type = constType;
                return innerValue;
            }
            return null;
        }

        // For now, report an error for unsupported initializer types
        _diagnostics.Add(Diagnostic.Error(
            $"unsupported global constant initializer for `{constName}`",
            initializer.Span,
            "global constant initializers must be compile-time constant expressions",
            "E3008"
        ));
        return null;
    }

    private Function LowerTestDeclaration(FLang.Frontend.Ast.Declarations.TestDeclarationNode testNode)
    {
        // Generate a unique function name for the test
        var testFnName = $"__test_{SanitizeTestName(testNode.Name)}";

        // Create a void function for the test
        var function = new Function(testFnName) { IsForeign = false, ReturnType = TypeRegistry.Void };
        _currentFunction = function;

        _currentBlock = CreateBlock("entry");
        function.BasicBlocks.Add(_currentBlock);

        // Push a new defer scope for this function
        _deferStack.Push([]);

        // Lower each statement in the test body
        foreach (var statement in testNode.Body)
        {
            LowerStatement(statement);
        }

        // Emit deferred statements at function end
        EmitDeferredStatements();

        // Pop the defer scope
        _deferStack.Pop();

        return function;
    }

    private static string SanitizeTestName(string name)
    {
        // Convert test name to valid C identifier
        var sanitized = new System.Text.StringBuilder();
        foreach (var c in name)
        {
            if (char.IsLetterOrDigit(c))
                sanitized.Append(c);
            else if (c == ' ')
                sanitized.Append('_');
            // Skip other characters
        }
        return sanitized.ToString();
    }

    private Function LowerFunction(FunctionDeclarationNode functionNode)
    {
        _currentFunctionNode = functionNode;
        var isForeign = (functionNode.Modifiers & FunctionModifiers.Foreign) != 0;

        // Use pre-resolved types from TypeChecker (should always be set)
        var retType = functionNode.ResolvedReturnType ??
                      throw new InvalidOperationException($"Function '{functionNode.Name}' has no resolved return type - TypeChecker must set ResolvedReturnType");

        var resolvedParamTypes = functionNode.ResolvedParameterTypes ??
                                 throw new InvalidOperationException($"Function '{functionNode.Name}' has no resolved parameter types - TypeChecker must set ResolvedParameterTypes");

        // Keep base name in IR; backend will mangle
        var function = new Function(functionNode.Name) { IsForeign = isForeign, ReturnType = retType };
        _currentFunction = function;

        // Clear parameter set for new function
        _parameters.Clear();

        // Add parameters to function
        for (var i = 0; i < functionNode.Parameters.Count; i++)
        {
            var param = functionNode.Parameters[i];
            var paramType = resolvedParamTypes[i];
            function.Parameters.Add(new FunctionParameter(param.Name, paramType));

            // Add parameter to locals with type so it can be referenced in the function body
            var localParam = new LocalValue(param.Name, paramType);
            _locals[param.Name] = localParam;
            _parameters.Add(param.Name);
        }

        // Foreign functions have no body
        if (isForeign) return function;

        _currentBlock = CreateBlock("entry");
        function.BasicBlocks.Add(_currentBlock);

        // Push a new defer scope for this function
        _deferStack.Push([]);

        foreach (var statement in functionNode.Body) LowerStatement(statement);

        // Emit deferred statements at function end (if no explicit return)
        EmitDeferredStatements();

        // Pop the defer scope
        _deferStack.Pop();

        // Add all created blocks to function first
        foreach (var block in _allBlocks)
            if (!function.BasicBlocks.Contains(block))
                function.BasicBlocks.Add(block);

        // Add implicit return for void functions - check ALL blocks, not just current
        // This handles cases where nested if-expressions leave multiple merge blocks
        // Compare by name since ResolvedReturnType might not be the exact TypeRegistry.Void instance
        var isVoidFunc = retType == TypeRegistry.Void || retType?.Name == "void";
        if (isVoidFunc)
        {
            foreach (var block in function.BasicBlocks)
            {
                if (block.Instructions.Count == 0)
                {
                    // Empty block needs a return
                    block.Instructions.Add(new ReturnInstruction(new ConstantValue(0) { Type = TypeRegistry.Void }));
                }
                else
                {
                    var lastInst = block.Instructions[^1];
                    var hasTerminator = lastInst is ReturnInstruction or JumpInstruction or BranchInstruction;
                    if (!hasTerminator)
                    {
                        block.Instructions.Add(new ReturnInstruction(new ConstantValue(0) { Type = TypeRegistry.Void }));
                    }
                }
            }
        }

        return function;
    }


    private BasicBlock CreateBlock(string hint)
    {
        var block = new BasicBlock($"{hint}_{_blockCounter++}");
        _allBlocks.Add(block);
        return block;
    }

    /// <summary>
    /// Generate a unique IR name for a variable, handling shadowing.
    /// First declaration uses the original name, subsequent ones get a numeric suffix.
    /// </summary>
    private string GetUniqueVariableName(string sourceName)
    {
        if (!_shadowCounter.TryGetValue(sourceName, out var count))
        {
            _shadowCounter[sourceName] = 0;
            return sourceName;
        }

        _shadowCounter[sourceName] = count + 1;
        return $"{sourceName}__shadow{count + 1}";
    }

    private static string SanitizeTypeName(string name)
    {
        return name.Replace("&", "ref_")
            .Replace("[", "_")
            .Replace("]", "_")
            .Replace("(", "_")
            .Replace(")", "_")
            .Replace(" ", "")
            .Replace(";", "_");
    }

    private void EnsureTypeTableExists()
    {
        if (_typeTableGlobal != null) return;

        // Ensure all field types of struct types are also in the instantiated set
        // Filter out unresolved generic parameter types (e.g., $T from generic functions)
        var allTypes = new HashSet<TypeBase>(
            _compilation.InstantiatedTypes.Where(t => t is not GenericParameterType));
        bool changed = true;
        while (changed)
        {
            changed = false;
            foreach (var type in allTypes.ToList())
            {
                // Only expand fields of user-defined structs, not RTTI internal types
                if (type is StructType structType
                    && !TypeRegistry.IsType(structType)
                    && !TypeRegistry.IsField(structType)
                    && !TypeRegistry.IsString(structType))
                {
                    foreach (var (_, fieldType) in structType.Fields)
                    {
                        if (fieldType is not GenericParameterType && allTypes.Add(fieldType))
                            changed = true;
                    }
                }
            }
        }

        // Remove any remaining unresolvable types (e.g. reference types wrapping generics)
        allTypes.RemoveWhere(t => t is GenericParameterType);
        allTypes.RemoveWhere(t => t is ReferenceType rt && rt.InnerType is GenericParameterType);

        // Build the type table from all types, sorted for deterministic layout
        var types = allTypes.OrderBy(t => t.Name).ToList();

        // First pass: assign indices
        for (int i = 0; i < types.Count; i++)
            _typeTableIndices[types[i]] = i;

        // Create the global type table first (forward reference for field type_info pointers)
        // We'll set the initializer after building all elements
        var fieldsSliceType = TypeRegistry.TypeStructTemplate.GetFieldType("fields") as StructType;

        var typeStructElements = new List<Value>();

        for (int i = 0; i < types.Count; i++)
        {
            var type = types[i];

            // For user-defined structs, use the FQN if available
            var typeName = type is StructType st && st.StructName is string fqn
                ? fqn
                : type.Name;
            // Create an inline ArrayConstantValue for the type name - the C code generator
            // will inline this directly as a string literal rather than creating a separate global
            var nameBytes = System.Text.Encoding.UTF8.GetBytes(typeName + "\0");
            var nameArray = new ArrayConstantValue(nameBytes, TypeRegistry.U8)
            {
                StringRepresentation = typeName
            };

            var nameString = new StructConstantValue(TypeRegistry.StringStruct, new Dictionary<string, Value>
            {
                ["ptr"] = nameArray,
                ["len"] = new ConstantValue(typeName.Length) { Type = TypeRegistry.USize }
            });

            // Build fields slice for this type
            Value fieldsSlice;
            if (type is StructType structType && structType.Fields.Count > 0
                && !TypeRegistry.IsType(structType))
            {
                var fieldElements = new List<Value>();
                foreach (var (fieldName, fieldType) in structType.Fields)
                {
                    // Field name as String
                    var fnameBytes = System.Text.Encoding.UTF8.GetBytes(fieldName + "\0");
                    var fnameArray = new ArrayConstantValue(fnameBytes, TypeRegistry.U8)
                    {
                        StringRepresentation = fieldName
                    };
                    var fnameString = new StructConstantValue(TypeRegistry.StringStruct, new Dictionary<string, Value>
                    {
                        ["ptr"] = fnameArray,
                        ["len"] = new ConstantValue(fieldName.Length) { Type = TypeRegistry.USize }
                    });

                    // Field offset
                    var offset = structType.GetFieldOffset(fieldName);

                    // type_info: NULL for now, can be resolved at runtime via type table index
                    var fieldStruct = new StructConstantValue(TypeRegistry.FieldStruct, new Dictionary<string, Value>
                    {
                        ["name"] = fnameString,
                        ["offset"] = new ConstantValue(offset) { Type = TypeRegistry.USize },
                        ["type_info"] = new ConstantValue(0) { Type = new ReferenceType(TypeRegistry.U8, PointerWidth.Bits64) }
                    });
                    fieldElements.Add(fieldStruct);
                }

                // Create global array for fields
                var fieldArrayType = new ArrayType(TypeRegistry.FieldStruct, fieldElements.Count);
                var fieldArray = new ArrayConstantValue(fieldArrayType, fieldElements.ToArray());
                var fieldGlobal = new GlobalValue($"__flang__type_{i}_fields", fieldArray);
                _currentFunction.Globals.Add(fieldGlobal);

                fieldsSlice = new StructConstantValue(fieldsSliceType!, new Dictionary<string, Value>
                {
                    ["ptr"] = fieldGlobal,
                    ["len"] = new ConstantValue(fieldElements.Count) { Type = TypeRegistry.USize }
                });
            }
            else
            {
                // No fields - empty slice
                fieldsSlice = new StructConstantValue(fieldsSliceType!, new Dictionary<string, Value>
                {
                    ["ptr"] = new ConstantValue(0) { Type = new ReferenceType(TypeRegistry.FieldStruct, PointerWidth.Bits64) },
                    ["len"] = new ConstantValue(0) { Type = TypeRegistry.USize }
                });
            }

            var typeStruct = new StructConstantValue(TypeRegistry.TypeStructTemplate, new Dictionary<string, Value>
            {
                ["name"] = nameString,
                ["size"] = new ConstantValue(type.Size) { Type = TypeRegistry.U8 },
                ["align"] = new ConstantValue(type.Alignment) { Type = TypeRegistry.U8 },
                ["fields"] = fieldsSlice
            });

            typeStructElements.Add(typeStruct);
        }

        // Create the global type table array
        var arrayType = new ArrayType(TypeRegistry.TypeStructTemplate, types.Count);
        var typeTableArray = new ArrayConstantValue(arrayType, typeStructElements.ToArray());
        _typeTableGlobal = new GlobalValue("__flang__type_table", typeTableArray);
        _currentFunction.Globals.Add(_typeTableGlobal);
    }

    private Value GetTypeLiteralValue(FType referencedType, StructType typeStructType)
    {
        EnsureTypeTableExists();

        // Get the index for this type in the table
        if (!_typeTableIndices.TryGetValue(referencedType, out var index))
        {
            throw new InvalidOperationException($"Type {referencedType.Name} was not collected during type checking");
        }

        // Calculate byte offset: index * sizeof(struct Type)
        var typeSize = TypeRegistry.TypeStructTemplate.Size;
        var byteOffset = new ConstantValue(index * typeSize) { Type = TypeRegistry.USize };

        // Get pointer to the element: &__flang__type_table[index]
        var elemPtr = new LocalValue($"type_ptr_{_tempCounter++}", new ReferenceType(typeStructType));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(_typeTableGlobal, byteOffset, elemPtr));

        return elemPtr;
    }

    private void LowerStatement(StatementNode statement)
    {
        switch (statement)
        {
            case VariableDeclarationNode varDecl:
                {
                    // Use pre-resolved type from TypeChecker (should always be set)
                    FType varType = varDecl.ResolvedType ??
                                    throw new InvalidOperationException($"Variable '{varDecl.Name}' has no resolved type - TypeChecker must set ResolvedType");

                    // Generate unique IR name for variable (handles shadowing)
                    var uniqueName = GetUniqueVariableName(varDecl.Name);

                    // Check if this is a struct or array type
                    bool isStruct = varType is StructType;
                    bool isArray = varType is ArrayType;

                    if (isStruct)
                    {
                        var structType = (StructType)varType;

                        // IMPORTANT: Evaluate initializer BEFORE updating _locals for shadowing to work
                        // (e.g., `let x = x + 1` should use the old x value)
                        Value? initValue = null;
                        if (varDecl.Initializer != null)
                        {
                            initValue = LowerExpression(varDecl.Initializer);
                        }

                        // Allocate stack space for struct
                        var allocaResult = new LocalValue(uniqueName, new ReferenceType(varType));
                        var allocaInst = new AllocaInstruction(varType, varType.Size, allocaResult);
                        _currentBlock.Instructions.Add(allocaInst);

                        // Store the POINTER in locals map (use source name for lookup)
                        _locals[varDecl.Name] = allocaResult;

                        // Handle initialization
                        if (initValue != null)
                        {
                            // Pointer to struct: use memcpy
                            if (initValue.Type is ReferenceType { InnerType: StructType })
                            {
                                // Copy struct fields from initializer
                                CopyStruct(allocaResult, initValue, structType);
                            }
                            else if (TryWriteSliceFromArray(allocaResult, structType, initValue))
                            {
                                // Slice initialized from array pointer; fields were populated above
                            }
                            // Struct value (e.g., from cast): store it directly
                            else if (initValue.Type is StructType)
                            {
                                var storeInst = new StorePointerInstruction(allocaResult, initValue);
                                _currentBlock.Instructions.Add(storeInst);
                            }
                        }
                        else
                        {
                            // Zero-initialize struct with memset
                            ZeroInitialize(allocaResult, structType.Size);
                        }
                    }
                    else if (isArray)
                    {
                        var arrayType = (ArrayType)varType;

                        // For arrays, we need special handling for memset optimization
                        // Check if we can use memset optimization (doesn't need old variable values)
                        bool useMemsetOptimization = false;
                        byte memsetByteVal = 0;
                        if (varDecl.Initializer is ArrayLiteralExpressionNode arrayLit && arrayLit.IsRepeatSyntax)
                        {
                            var elemSize = arrayType.ElementType.Size;
                            if (arrayLit.RepeatValue is IntegerLiteralNode intLit &&
                                (intLit.Value == 0 || elemSize == 1))
                            {
                                useMemsetOptimization = true;
                                memsetByteVal = (byte)(intLit.Value & 0xFF);
                            }
                        }

                        // For non-memset cases, evaluate initializer BEFORE updating _locals
                        Value? initValue = null;
                        if (varDecl.Initializer != null && !useMemsetOptimization)
                        {
                            initValue = LowerExpression(varDecl.Initializer);
                        }

                        // Allocate stack space for array
                        var allocaResult = new LocalValue(uniqueName, new ReferenceType(arrayType));
                        var allocaInst = new AllocaInstruction(arrayType, arrayType.Size, allocaResult);
                        _currentBlock.Instructions.Add(allocaInst);

                        // Store the POINTER in locals map (use source name for lookup)
                        _locals[varDecl.Name] = allocaResult;

                        // Handle initialization
                        if (useMemsetOptimization)
                        {
                            // Use memset only for zero value OR byte-sized elements
                            var zeroValue = new ConstantValue(memsetByteVal) { Type = TypeRegistry.U8 };
                            var sizeValue = new ConstantValue(arrayType.Size) { Type = TypeRegistry.USize };
                            var memsetResult = new LocalValue($"memset_{_tempCounter++}", TypeRegistry.Void);

                            var memsetCall = new CallInstruction("memset",
                                new List<Value> { allocaResult, zeroValue, sizeValue },
                                memsetResult)
                            {
                                IsForeignCall = true
                            };
                            _currentBlock.Instructions.Add(memsetCall);
                        }
                        else if (initValue != null)
                        {
                            if (initValue is GlobalValue globalArray)
                            {
                                EmitArrayMemcpy(allocaResult, globalArray, arrayType.Size);
                            }
                        }
                        else
                        {
                            // Zero-initialize array with memset
                            ZeroInitialize(allocaResult, arrayType.Size);
                        }
                    }
                    else
                    {
                        // Scalars: allocate on stack like arrays/structs (memory-based SSA)

                        // IMPORTANT: Evaluate initializer BEFORE updating _locals for shadowing to work
                        // (e.g., `let x = x + 1` should use the old x value)
                        Value? initValue = null;
                        if (varDecl.Initializer != null)
                        {
                            initValue = LowerExpression(varDecl.Initializer);
                        }

                        var allocaResult = new LocalValue(uniqueName, new ReferenceType(varType));
                        var allocaInst = new AllocaInstruction(varType, varType.Size, allocaResult);
                        _currentBlock.Instructions.Add(allocaInst);

                        // Store the POINTER in locals map (use source name for lookup)
                        _locals[varDecl.Name] = allocaResult;

                        // Handle initialization
                        if (initValue != null)
                        {
                            var initStoreInst = new StorePointerInstruction(allocaResult, initValue);
                            _currentBlock.Instructions.Add(initStoreInst);
                        }
                        else
                        {
                            // Zero-initialize scalar with store 0
                            var zeroValue = new ConstantValue(0) { Type = varType };
                            var zeroStoreInst = new StorePointerInstruction(allocaResult, zeroValue);
                            _currentBlock.Instructions.Add(zeroStoreInst);
                        }
                    }

                    break;
                }

            case ReturnStatementNode returnStmt:
                // Execute deferred statements before returning (in LIFO order)
                EmitDeferredStatements();
                if (returnStmt.Expression != null)
                {
                    var returnValue = LowerExpression(returnStmt.Expression);
                    _currentBlock.Instructions.Add(new ReturnInstruction(returnValue));
                }
                else
                {
                    // Bare return for void functions
                    _currentBlock.Instructions.Add(new ReturnInstruction(null));
                }
                break;

            case BreakStatementNode breakStmt:
                if (_loopStack.Count == 0)
                    _diagnostics.Add(Diagnostic.Error(
                        "`break` statement outside of loop",
                        breakStmt.Span,
                        "`break` can only be used inside a loop",
                        "E3006"
                    ));
                else
                    _currentBlock.Instructions.Add(new JumpInstruction(_loopStack.Peek().BreakTarget));
                break;

            case ContinueStatementNode continueStmt:
                if (_loopStack.Count == 0)
                    _diagnostics.Add(Diagnostic.Error(
                        "`continue` statement outside of loop",
                        continueStmt.Span,
                        "`continue` can only be used inside a loop",
                        "E3007"
                    ));
                else
                    _currentBlock.Instructions.Add(new JumpInstruction(_loopStack.Peek().ContinueTarget));
                break;

            case ForLoopNode forLoop:
                LowerForLoop(forLoop);
                break;

            case DeferStatementNode deferStmt:
                // Add the deferred expression to the current scope's defer list
                if (_deferStack.Count > 0)
                    _deferStack.Peek().Add(deferStmt.Expression);
                break;

            case ExpressionStatementNode exprStmt:
                // Just evaluate the expression for its side effects (e.g., assignment)
                LowerExpression(exprStmt.Expression);
                break;
        }
    }

    /// <summary>
    /// Emits all deferred statements from the current scope in LIFO order.
    /// Called before returns and at the end of scopes.
    /// </summary>
    private void EmitDeferredStatements()
    {
        if (_deferStack.Count == 0) return;

        var deferredExpressions = _deferStack.Peek();
        // Execute in LIFO order (reverse)
        for (var i = deferredExpressions.Count - 1; i >= 0; i--)
        {
            LowerExpression(deferredExpressions[i]);
        }
    }

    private Value LowerExpression(ExpressionNode expression)
    {
        var value = LowerExpressionCore(expression);
        var finalType = expression.Type;

        _logger.LogDebug(
            "[AstLowering] LowerExpression: exprType={ExpressionType}, value.Type={ValueType}, finalType={FinalType}",
            expression.GetType().Name, value.Type?.Name ?? "null", finalType?.Name ?? "null");

        // If final type is Option<T> but value is T, wrap it
        if (finalType is StructType st && TypeRegistry.IsOption(st) &&
            st.TypeArguments.Count > 0 && value.Type != null && value.Type.Equals(st.TypeArguments[0]))
        {
            _logger.LogDebug("[AstLowering] Wrapping value in Option: {ValueType} -> {OptionType}",
                value.Type.Name, st.Name);
            return LowerLiftToOption(value, st);
        }

        return value;
    }

    private Value LowerExpressionCore(ExpressionNode expression)
    {
        switch (expression)
        {
            case ImplicitCoercionNode coercion:
                return LowerImplicitCoercion(coercion);

            case IntegerLiteralNode intLiteral:
                {
                    var literalType = expression.Type;
                    var valueType =
                        (literalType is StructType st && TypeRegistry.IsOption(st) && st.TypeArguments.Count > 0)
                            ? st.TypeArguments[0]
                            : literalType ?? TypeRegistry.ComptimeInt;
                    return new ConstantValue(intLiteral.Value) { Type = valueType };
                }

            case BooleanLiteralNode boolLiteral:
                {
                    var literalType = expression.Type;
                    var valueType =
                        (literalType is StructType st && TypeRegistry.IsOption(st) && st.TypeArguments.Count > 0)
                            ? st.TypeArguments[0]
                            : literalType ?? TypeRegistry.Bool;
                    return new ConstantValue(boolLiteral.Value ? 1 : 0) { Type = valueType };
                }


            case StringLiteralNode stringLiteral:
                {
                    // String literals are represented as String struct constants
                    var sid = _compilation.AllocateStringId();
                    var globalName = $"LC{sid}"; // Use LC0, LC1, LC2... naming

                    // Convert string to byte array (UTF-8 + null terminator for C FFI)
                    var bytes = System.Text.Encoding.UTF8.GetBytes(stringLiteral.Value);
                    var nullTerminated = new byte[bytes.Length + 1];
                    Array.Copy(bytes, nullTerminated, bytes.Length);

                    // Create array constant for the raw bytes
                    var arrayConst = new ArrayConstantValue(nullTerminated, TypeRegistry.U8)
                    {
                        StringRepresentation = stringLiteral.Value
                    };

                    // Get String struct type from type solver
                    var stringType = stringLiteral.Type as StructType;
                    if (stringType == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "String type not found for string literal",
                            stringLiteral.Span,
                            "import core.string",
                            "E3010"
                        ));
                        return new ConstantValue(0);
                    }

                    // Create String struct constant: { ptr: <bytes>, len: <length> }
                    var structConst = new StructConstantValue(stringType, new Dictionary<string, Value>
                    {
                        ["ptr"] = arrayConst,
                        ["len"] = new ConstantValue(bytes.Length) { Type = TypeRegistry.USize }
                    });

                    // Create global (type will be &String)
                    var global = new GlobalValue(globalName, structConst);

                    // Register in function globals
                    _currentFunction.Globals.Add(global);

                    // Return the global - it's a pointer to String struct
                    return global;
                }

            case IdentifierExpressionNode identifier:
                {
                    var identType = identifier.Type;

                    // Check if this is a function reference (function pointer)
                    if (identType is FunctionType && identifier.ResolvedFunctionTarget != null)
                    {
                        // Create a function reference value
                        var funcRefValue = new FunctionReferenceValue(identifier.ResolvedFunctionTarget.Name, identType);
                        return funcRefValue;
                    }

                    // Check if this is an unqualified enum variant (e.g., `Red` instead of `Color.Red`)
                    // Only treat as variant if the enum actually has a variant with this name
                    if (identType is EnumType variantEnumType &&
                        variantEnumType.Variants.Any(v => v.VariantName == identifier.Name))
                    {
                        // This is a unit variant - lower it as enum construction with no arguments
                        // Create a synthetic CallExpressionNode to reuse existing lowering logic
                        var syntheticCall =
                            new CallExpressionNode(identifier.Span, identifier.Name, new List<ExpressionNode>());
                        return LowerEnumConstruction(syntheticCall, variantEnumType);
                    }

                    // Check locals/parameters FIRST - this handles Type(T) parameters correctly
                    // Type literals (like `i32` as a bare expression) are handled below if not a local
                    if (_locals.TryGetValue(identifier.Name, out var localValue))
                    {
                        // Parameters are passed by value (even if they're pointers), so use them directly
                        if (_parameters.Contains(identifier.Name))
                        {
                            return localValue;
                        }

                        // Local variables are now pointers (alloca'd)
                        if (localValue.Type is ReferenceType refType)
                        {
                            // Arrays and structs: return the pointer directly (don't load)
                            // They are manipulated via pointer in the IR
                            if (refType.InnerType is ArrayType or StructType)
                            {
                                return localValue;
                            }

                            // Scalars: load the value from memory
                            var loadedValue = new LocalValue($"{identifier.Name}_load_{_tempCounter++}", refType.InnerType);
                            var loadInstruction = new LoadInstruction(localValue, loadedValue);
                            _currentBlock.Instructions.Add(loadInstruction);
                            return loadedValue;
                        }

                        // Shouldn't happen with new approach, but keep for safety
                        return localValue;
                    }

                    // Check if it's a global constant
                    if (_compilation.LoweredGlobalConstants.TryGetValue(identifier.Name, out var globalConstValue) && globalConstValue is Value gv)
                    {
                        // For GlobalValue (struct constants), add to function's globals and return it
                        if (gv is GlobalValue globalVal)
                        {
                            if (!_currentFunction.Globals.Contains(globalVal))
                            {
                                _currentFunction.Globals.Add(globalVal);
                            }
                            return globalVal;
                        }
                        // For ConstantValue (scalar constants), return directly
                        return gv;
                    }

                    // Check if this is a type literal (not a variable/parameter)
                    // This handles cases like `size_of(i32)` where `i32` is a type name used as an expression
                    if (identType is StructType st && TypeRegistry.IsType(st) && st.TypeArguments.Count > 0)
                    {
                        var referencedType = st.TypeArguments[0];
                        // Load type metadata from global type table
                        var typeGlobal = GetTypeLiteralValue(referencedType, st);

                        // Load the struct value
                        var loaded = new LocalValue($"type_load_{_tempCounter++}", st);
                        _currentBlock.Instructions.Add(new LoadInstruction(typeGlobal, loaded));
                        return loaded;
                    }

                    _diagnostics.Add(Diagnostic.Error(
                        $"cannot find value `{identifier.Name}` during lowering",
                        identifier.Span,
                        "this may indicate a bug in the type checker",
                        "E3004"
                    ));
                    // Return a dummy value to avoid cascading errors
                    return new ConstantValue(0);
                }

            case BinaryExpressionNode binary when binary.Operator is BinaryOperatorKind.And or BinaryOperatorKind.Or:
                {
                    return LowerShortCircuitLogical(binary);
                }

            case BinaryExpressionNode binary:
                {
                    var left = LowerExpression(binary.Left);
                    var right = LowerExpression(binary.Right);

                    // Check if operator resolved to a function call
                    if (binary.ResolvedOperatorFunction != null)
                    {
                        // Emit function call for operator
                        return LowerOperatorFunctionCall(binary, left, right);
                    }

                    // Fall back to built-in binary instruction
                    var op = binary.Operator switch
                    {
                        BinaryOperatorKind.Add => BinaryOp.Add,
                        BinaryOperatorKind.Subtract => BinaryOp.Subtract,
                        BinaryOperatorKind.Multiply => BinaryOp.Multiply,
                        BinaryOperatorKind.Divide => BinaryOp.Divide,
                        BinaryOperatorKind.Modulo => BinaryOp.Modulo,
                        BinaryOperatorKind.Equal => BinaryOp.Equal,
                        BinaryOperatorKind.NotEqual => BinaryOp.NotEqual,
                        BinaryOperatorKind.LessThan => BinaryOp.LessThan,
                        BinaryOperatorKind.GreaterThan => BinaryOp.GreaterThan,
                        BinaryOperatorKind.LessThanOrEqual => BinaryOp.LessThanOrEqual,
                        BinaryOperatorKind.GreaterThanOrEqual => BinaryOp.GreaterThanOrEqual,
                        _ => throw new Exception($"Unknown binary operator: {binary.Operator}")
                    };

                    var temp = new LocalValue($"t{_tempCounter++}", binary.Type!);
                    var instruction = new BinaryInstruction(op, left, right, temp);
                    _currentBlock.Instructions.Add(instruction);
                    return temp;
                }

            case UnaryExpressionNode unary:
                {
                    var operand = LowerExpression(unary.Operand);

                    // Check if operator resolved to a function call
                    if (unary.ResolvedOperatorFunction != null)
                    {
                        return LowerUnaryOperatorFunctionCall(unary, operand);
                    }

                    // Fall back to built-in unary instruction
                    var uop = unary.Operator switch
                    {
                        UnaryOperatorKind.Negate => UnaryOp.Negate,
                        UnaryOperatorKind.Not => UnaryOp.Not,
                        _ => throw new Exception($"Unknown unary operator: {unary.Operator}")
                    };

                    var temp = new LocalValue($"t{_tempCounter++}", unary.Type!);
                    var instruction = new UnaryInstruction(uop, operand, temp);
                    _currentBlock.Instructions.Add(instruction);
                    return temp;
                }

            case AssignmentExpressionNode assignment:
                {
                    // Handle indexed assignment: expr[index] = value
                    if (assignment.Target is IndexExpressionNode indexTarget)
                    {
                        return LowerIndexedAssignment(assignment, indexTarget);
                    }

                    var assignValue = LowerExpression(assignment.Value);

                    // Get the pointer to the assignment target (lvalue)
                    Value targetPtr = assignment.Target switch
                    {
                        IdentifierExpressionNode id => GetVariablePointer(id, assignment),
                        MemberAccessExpressionNode fa => GetFieldPointer(fa),
                        DereferenceExpressionNode dr => LowerExpression(dr.Target),
                        _ => throw new Exception($"Invalid assignment target: {assignment.Target.GetType().Name}")
                    };

                    if (targetPtr.Type is ReferenceType { InnerType: StructType targetStruct })
                    {
                        if (assignValue.Type is ReferenceType { InnerType: StructType sourceStruct } &&
                            targetStruct.Equals(sourceStruct))
                        {
                            CopyStruct(targetPtr, assignValue, targetStruct);
                            return assignValue;
                        }

                        if (TryWriteSliceFromArray(targetPtr, targetStruct, assignValue))
                            return assignValue;
                    }

                    // Store to the memory location (no versioning needed)
                    var assignStoreInst = new StorePointerInstruction(targetPtr, assignValue);
                    _currentBlock.Instructions.Add(assignStoreInst);

                    // Assignment expressions return the assigned value
                    return assignValue;
                }

            case IfExpressionNode ifExpr:
                return LowerIfExpression(ifExpr);

            case BlockExpressionNode blockExpr:
                return LowerBlockExpression(blockExpr);

            case RangeExpressionNode rangeExpr:
                // Lower range expression to Range struct construction: .{ start = ..., end = ... }
                return LowerRangeToStruct(rangeExpr);

            case CoalesceExpressionNode coalesce:
                return LowerCoalesceExpression(coalesce);

            case NullPropagationExpressionNode nullProp:
                return LowerNullPropagationExpression(nullProp);

            case MatchExpressionNode match:
                return LowerMatchExpression(match);

            case CallExpressionNode call:
                // Check if this is enum variant construction
                var exprType = call.Type;
                if (exprType is EnumType enumType)
                {
                    return LowerEnumConstruction(call, enumType);
                }

                // size_of and align_of are now regular library functions defined in core.rtti
                // They accept Type($T) parameters and access struct fields directly

                // Handle field-access-then-call (vtable pattern): ops.add(5, 3)
                // Detected by: IsIndirectCall + UfcsReceiver/MethodName set (not a simple variable call)
                if (call.IsIndirectCall && call.UfcsReceiver != null && call.MethodName != null)
                {
                    // Lower the receiver to get the struct value/pointer
                    var receiverVal = LowerExpression(call.UfcsReceiver);
                    var receiverType = call.UfcsReceiver.Type?.Prune();

                    // Get the struct type
                    var structType = receiverType switch
                    {
                        StructType st => st,
                        ReferenceType { InnerType: StructType refSt } => refSt,
                        _ => throw new InvalidOperationException($"Field call receiver is not a struct type: {receiverType}")
                    };

                    // Get field offset and type
                    var fieldOffset = structType.GetFieldOffset(call.MethodName);
                    var fieldType = structType.GetFieldType(call.MethodName);
                    if (fieldType is not FunctionType funcFieldType)
                        throw new InvalidOperationException($"Field '{call.MethodName}' is not a function type");

                    // Get pointer to the field
                    var fieldPtrType = new ReferenceType(funcFieldType);
                    var fieldPtr = new LocalValue($"field_ptr_{_tempCounter++}", fieldPtrType);
                    var gepInst = new GetElementPtrInstruction(receiverVal, fieldOffset, fieldPtr);
                    _currentBlock.Instructions.Add(gepInst);

                    // Load the function pointer from the field
                    var funcPtrValue = new LocalValue($"fptr_load_{_tempCounter++}", funcFieldType);
                    var funcLoadInst = new LoadInstruction(fieldPtr, funcPtrValue);
                    _currentBlock.Instructions.Add(funcLoadInst);

                    // Lower arguments
                    var fieldCallArgs = new List<Value>();
                    for (var i = 0; i < call.Arguments.Count; i++)
                    {
                        var argVal = LowerExpression(call.Arguments[i]);
                        fieldCallArgs.Add(argVal);
                    }

                    var fieldCallType = exprType ?? TypeRegistry.Never;
                    var fieldCallResult = new LocalValue($"call_{_tempCounter++}", fieldCallType);
                    var fieldCallInst = new IndirectCallInstruction(funcPtrValue, fieldCallArgs, fieldCallResult);
                    _currentBlock.Instructions.Add(fieldCallInst);
                    return fieldCallResult;
                }

                // Handle indirect calls (through function pointers)
                if (call.IsIndirectCall)
                {
                    // The function name is actually a variable holding a function pointer
                    Value funcPtrValue;
                    if (_locals.TryGetValue(call.FunctionName, out var localPtr))
                    {
                        // Load the function pointer from the local variable
                        var funcLoadResult = new LocalValue($"fptr_load_{_tempCounter++}", localPtr.Type is ReferenceType indirectRt ? indirectRt.InnerType : localPtr.Type!);
                        var funcLoadInst = new LoadInstruction(localPtr, funcLoadResult);
                        _currentBlock.Instructions.Add(funcLoadInst);
                        funcPtrValue = funcLoadResult;
                    }
                    else
                    {
                        throw new InvalidOperationException($"Cannot find function pointer variable '{call.FunctionName}'");
                    }

                    // Lower arguments
                    var indirectArgs = new List<Value>();
                    for (var i = 0; i < call.Arguments.Count; i++)
                    {
                        var argVal = LowerExpression(call.Arguments[i]);
                        indirectArgs.Add(argVal);
                    }

                    var indirectCallType = exprType ?? TypeRegistry.Never;
                    var indirectCallResult = new LocalValue($"call_{_tempCounter++}", indirectCallType);
                    var indirectCallInst = new IndirectCallInstruction(funcPtrValue, indirectArgs, indirectCallResult);
                    _currentBlock.Instructions.Add(indirectCallInst);
                    return indirectCallResult;
                }

                // UFCS call: receiver.method(args) -> method(receiver, args) or method(&receiver, args)
                // Handle the implicit receiver argument based on what the function expects
                Value? ufcsReceiverArg = null;
                if (call.UfcsReceiver != null && call.MethodName != null && !call.IsIndirectCall)
                {
                    var receiverType = call.UfcsReceiver.Type?.Prune();

                    // Check what the first parameter of the resolved function expects
                    var firstParamExpectsRef = false;
                    if (call.ResolvedTarget?.Parameters.Count > 0)
                    {
                        var firstParamType = call.ResolvedTarget.Parameters[0].ResolvedType?.Prune();
                        firstParamExpectsRef = firstParamType is ReferenceType;
                    }

                    var receiverIsRef = receiverType is ReferenceType;

                    if (firstParamExpectsRef)
                    {
                        // Function expects a reference
                        if (receiverIsRef)
                        {
                            // Already a reference, use directly
                            var receiverVal = LowerExpression(call.UfcsReceiver);
                            ufcsReceiverArg = receiverVal;
                        }
                        else if (call.UfcsReceiver is MemberAccessExpressionNode fieldReceiver)
                        {
                            // Field access: use the field pointer directly so mutations
                            // persist in the parent struct (e.g., self.it.next() → next(&self.it))
                            ufcsReceiverArg = GetFieldPointer(fieldReceiver);
                        }
                        else
                        {
                            var receiverVal = LowerExpression(call.UfcsReceiver);
                            // Need to take address of the receiver
                            // If it's an lvalue (stored in memory), we can get its address directly
                            // If it's an rvalue (e.g., call result), we need to spill to a temp first
                            if (receiverVal is LocalValue lv && _locals.ContainsValue(lv))
                            {
                                // It's already a pointer to storage, use it directly
                                ufcsReceiverArg = lv;
                            }
                            else
                            {
                                // Rvalue - create temporary storage, store value, use address
                                var tempName = $"ufcs_temp_{_tempCounter++}";
                                var tempPtr = new LocalValue(tempName, new ReferenceType(receiverType!));
                                var allocaInst = new AllocaInstruction(receiverType!, receiverType!.Size, tempPtr);
                                _currentBlock.Instructions.Add(allocaInst);

                                var storeInst = new StorePointerInstruction(tempPtr, receiverVal);
                                _currentBlock.Instructions.Add(storeInst);

                                ufcsReceiverArg = tempPtr;
                            }
                        }
                    }
                    else
                    {
                        var receiverVal = LowerExpression(call.UfcsReceiver);
                        // Function expects a value
                        if (receiverIsRef)
                        {
                            // Receiver is a reference but function expects value - dereference it
                            var innerType = ((ReferenceType)receiverType!).InnerType;
                            var ufcsDerefResult = new LocalValue($"ufcs_deref_{_tempCounter++}", innerType);
                            var ufcsDerefInst = new LoadInstruction(receiverVal, ufcsDerefResult);
                            _currentBlock.Instructions.Add(ufcsDerefInst);
                            ufcsReceiverArg = ufcsDerefResult;
                        }
                        else
                        {
                            // Value receiver, value expected - pass as-is
                            ufcsReceiverArg = receiverVal;
                        }
                    }
                }

                // Regular function call
                var paramTypes = new List<FType>();
                if (call.ResolvedTarget != null)
                {
                    foreach (var param in call.ResolvedTarget.Parameters)
                    {
                        // Use pre-resolved type from TypeChecker (should always be set)
                        var paramType = param.ResolvedType ??
                                        throw new InvalidOperationException($"Parameter '{param.Name}' has no resolved type - TypeChecker must set ResolvedType");
                        paramTypes.Add(paramType);
                    }
                }

                // Lower arguments, inserting implicit casts when needed
                var args = new List<Value>();

                // For UFCS, prepend the receiver argument
                if (ufcsReceiverArg != null)
                {
                    // Check if we need to cast the receiver
                    if (paramTypes.Count > 0 && ufcsReceiverArg.Type != null && !ufcsReceiverArg.Type.Equals(paramTypes[0]))
                    {
                        var recvCastResult = new LocalValue($"cast_{_tempCounter++}", paramTypes[0]);
                        var recvCastInst = new CastInstruction(ufcsReceiverArg, paramTypes[0], recvCastResult);
                        _currentBlock.Instructions.Add(recvCastInst);
                        args.Add(recvCastResult);
                    }
                    else
                    {
                        args.Add(ufcsReceiverArg);
                    }
                }

                // Lower explicit arguments
                var argOffset = ufcsReceiverArg != null ? 1 : 0;
                for (var i = 0; i < call.Arguments.Count; i++)
                {
                    var argVal = LowerExpression(call.Arguments[i]);
                    var argType = call.Arguments[i].Type;
                    var paramIdx = i + argOffset;

                    // Insert cast if argument type doesn't match parameter type but can coerce
                    if (paramIdx < paramTypes.Count && argType != null && !argType.Equals(paramTypes[paramIdx]))
                    {
                        var argCastResult = new LocalValue($"cast_{_tempCounter++}", paramTypes[paramIdx]);
                        // CastInstruction now infers cast kind from source and target types
                        var argCastInst = new CastInstruction(argVal, paramTypes[paramIdx], argCastResult);
                        _currentBlock.Instructions.Add(argCastInst);
                        args.Add(argCastResult);
                    }
                    else
                    {
                        args.Add(argVal);
                    }
                }

                var callType = exprType ?? TypeRegistry.Never;
                var callResult = new LocalValue($"call_{_tempCounter++}", callType);
                var targetName = call.ResolvedTarget?.Name ?? call.FunctionName;
                var callInst = new CallInstruction(targetName, args, callResult);
                if (call.ResolvedTarget != null)
                {
                    callInst.CalleeParamTypes = paramTypes;
                    callInst.IsForeignCall = (call.ResolvedTarget.Modifiers & FunctionModifiers.Foreign) != 0;
                }

                _currentBlock.Instructions.Add(callInst);
                return callResult;

            case AddressOfExpressionNode addressOf:
                // Address-of: &expr
                if (addressOf.Target is IdentifierExpressionNode addrIdentifier)
                {
                    // Check if this is a local variable (stored as pointer via alloca)
                    if (_locals.TryGetValue(addrIdentifier.Name, out var localValue))
                    {
                        // If it's already a pointer (alloca'd variable), return it directly
                        // This prevents double-pointer issues since all variables are now memory-based
                        if (localValue.Type is ReferenceType)
                        {
                            return localValue;
                        }
                    }

                    // Check if this is a global constant - GlobalValue already has pointer type
                    if (_compilation.LoweredGlobalConstants.TryGetValue(addrIdentifier.Name, out var globalConstValue)
                        && globalConstValue is GlobalValue globalVal)
                    {
                        if (!_currentFunction.Globals.Contains(globalVal))
                        {
                            _currentFunction.Globals.Add(globalVal);
                        }
                        return globalVal;
                    }

                    // For parameters or other non-alloca'd values, emit AddressOfInstruction
                    var addrResult = new LocalValue($"addr_{_tempCounter++}", addressOf.Type!);
                    var addrInst = new AddressOfInstruction(addrIdentifier.Name, addrResult);
                    _currentBlock.Instructions.Add(addrInst);
                    return addrResult;
                }

                if (addressOf.Target is IndexExpressionNode ixAddr)
                {
                    // Compute pointer to array element: &base[index]
                    var baseType = ixAddr.Base.Type;
                    var addrBaseValue = LowerExpression(ixAddr.Base);
                    var addrIndexValue = LowerExpression(ixAddr.Index);

                    if (baseType is ArrayType atAddr)
                    {
                        var elemSize = GetTypeSize(atAddr.ElementType);
                        // offset = index * elem_size
                        var offsetTemp = new LocalValue($"offset_{_tempCounter++}", TypeRegistry.USize);
                        var offsetInst = new BinaryInstruction(BinaryOp.Multiply, addrIndexValue,
                            new ConstantValue(elemSize) { Type = TypeRegistry.I32 }, offsetTemp);
                        _currentBlock.Instructions.Add(offsetInst);

                        // element pointer = base + offset
                        var elemPtr = new LocalValue($"index_ptr_{_tempCounter++}", new ReferenceType(atAddr.ElementType));
                        var gepInst = new GetElementPtrInstruction(addrBaseValue, offsetTemp, elemPtr);
                        _currentBlock.Instructions.Add(gepInst);
                        return elemPtr;
                    }

                    _diagnostics.Add(Diagnostic.Error(
                        "cannot take address of indexed non-array value",
                        addressOf.Span,
                        null,
                        "E3012"));
                    return new ConstantValue(0);
                }

                // For any other expression (e.g., call results, struct construction),
                // introduce a temporary variable to hold the value, then take its address.
                // This enables UFCS chaining like: x.foo().bar() where bar takes &T
                {
                    var innerValue = LowerExpression(addressOf.Target);
                    var innerType = addressOf.Target.Type ?? innerValue.Type;

                    // Create a temporary alloca for the value
                    var tempName = $"addr_temp_{_tempCounter++}";
                    var tempPtr = new LocalValue(tempName, new ReferenceType(innerType!));
                    var allocaInst = new AllocaInstruction(innerType!, innerType!.Size, tempPtr);
                    _currentBlock.Instructions.Add(allocaInst);

                    // Store the value into the temporary
                    var storeInst = new StorePointerInstruction(tempPtr, innerValue);
                    _currentBlock.Instructions.Add(storeInst);

                    // Return the pointer to the temporary
                    return tempPtr;
                }

            case DereferenceExpressionNode deref:
                // Dereference: ptr.*
                var ptrValue = LowerExpression(deref.Target);
                var loadResult = new LocalValue($"load_{_tempCounter++}", deref.Type!);
                var loadInst = new LoadInstruction(ptrValue, loadResult);
                _currentBlock.Instructions.Add(loadInst);
                return loadResult;

            case StructConstructionExpressionNode structCtor:
                {
                    var structType = GetExpressionType(structCtor) as StructType;
                    if (structType == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "struct construction expression has non-struct type after type checking",
                            structCtor.Span,
                            "type checking should have produced a concrete StructType",
                            "E3001"
                        ));
                        return new ConstantValue(0);
                    }

                    return LowerStructLiteral(structCtor.Fields, structType, structCtor.Span);
                }

            case AnonymousStructExpressionNode anonStruct:
                {
                    var structType = GetExpressionType(anonStruct) as StructType;
                    if (structType == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "anonymous struct expression has non-struct type after type checking",
                            anonStruct.Span,
                            "type checking should have produced a concrete StructType",
                            "E3001"
                        ));
                        return new ConstantValue(0);
                    }

                    return LowerStructLiteral(anonStruct.Fields, structType, anonStruct.Span);
                }

            case NullLiteralNode nullLiteral:
                {
                    var nullType = nullLiteral.Type as StructType;
                    if (nullType == null || !TypeRegistry.IsOption(nullType))
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "null literal requires an option type",
                            nullLiteral.Span,
                            "add an explicit option annotation",
                            "E3001"));
                        return new ConstantValue(0);
                    }

                    return LowerNullLiteral(nullType);
                }

            case CastExpressionNode cast:
                {
                    var srcVal = LowerExpression(cast.Expression);
                    var srcTypeForCast = cast.Expression.Type;
                    var dstType = cast.Type ?? TypeRegistry.Never;

                    // No-op if types are already identical
                    if (srcTypeForCast != null && srcTypeForCast.Equals(dstType))
                    {
                        srcVal.Type = dstType;
                        return srcVal;
                    }

                    // Emit CastInstruction for all casts
                    // The backend will determine the appropriate cast implementation by inspecting types
                    var castResult = new LocalValue($"cast_{_tempCounter++}", dstType);
                    var castInst = new CastInstruction(srcVal, dstType, castResult);
                    _currentBlock.Instructions.Add(castInst);
                    return castResult;
                }

            case MemberAccessExpressionNode fieldAccess:
                {
                    // Check if this is enum variant construction (e.g., Color.Blue)
                    // Only treat as variant if the enum actually has a variant with this name
                    var memberAccessType = fieldAccess.Type;
                    if (memberAccessType is EnumType enumFromMember &&
                        enumFromMember.Variants.Any(v => v.VariantName == fieldAccess.FieldName))
                    {
                        // This is EnumType.Variant syntax - lower as enum construction
                        var syntheticCall = new CallExpressionNode(fieldAccess.Span, fieldAccess.FieldName,
                            new List<ExpressionNode>());
                        return LowerEnumConstruction(syntheticCall, enumFromMember);
                    }

                    // Get struct type from the target expression
                    var targetValue = LowerExpression(fieldAccess.Target);
                    var targetSemanticType = fieldAccess.Target.Type;

                    // Handle special case for arrays: they can act as having the same fields as Slices (ptr and len)
                    if (targetSemanticType is ArrayType arrayType)
                    {
                        if (fieldAccess.FieldName == "ptr")
                        {
                            // ptr is an alias for the array itself but as reference
                            var elementPtrType = new ReferenceType(arrayType.ElementType);
                            var castResult = new LocalValue($"array_ptr_{_tempCounter++}", elementPtrType);
                            var castInst = new CastInstruction(targetValue, elementPtrType, castResult);
                            _currentBlock.Instructions.Add(castInst);
                            return castResult;
                        }

                        if (fieldAccess.FieldName == "len")
                        {
                            // len is replaced with the actual literal constant length of the array
                            return new ConstantValue(arrayType.Length) { Type = TypeRegistry.USize };
                        }
                    }

                    // Auto-dereference: if AutoDerefCount > 1, we need to dereference intermediate pointers
                    // AutoDerefCount=0: struct direct access (already a struct value)
                    // AutoDerefCount=1: &Struct - single pointer, no extra dereference needed (GEP handles it)
                    // AutoDerefCount=2: &&Struct - need to load once to get &Struct, then GEP
                    // AutoDerefCount=N: need to load N-1 times
                    var currentPtr = targetValue;
                    var currentType = targetSemanticType;
                    for (int i = 0; i < fieldAccess.AutoDerefCount - 1; i++)
                    {
                        // Dereference to get the next pointer level
                        if (currentType is ReferenceType refType)
                        {
                            var innerType = refType.InnerType;
                            var derefResult = new LocalValue($"autoderef_{_tempCounter++}", innerType);
                            var derefInst = new LoadInstruction(currentPtr, derefResult);
                            _currentBlock.Instructions.Add(derefInst);
                            currentPtr = derefResult;
                            currentType = innerType;
                        }
                    }

                    // Find the struct type by unwrapping references
                    var structTypeForAccess = currentType;
                    while (structTypeForAccess is ReferenceType rt)
                    {
                        structTypeForAccess = rt.InnerType;
                    }
                    var accessStruct = structTypeForAccess as StructType;

                    if (accessStruct == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "cannot access field on non-struct type",
                            fieldAccess.Span,
                            "type checking failed",
                            "E3002"
                        ));
                        return new ConstantValue(0);
                    }

                    // Calculate field offset
                    var fieldByteOffset = accessStruct.GetFieldOffset(fieldAccess.FieldName);
                    if (fieldByteOffset == -1)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            $"field `{fieldAccess.FieldName}` not found",
                            fieldAccess.Span,
                            "type checking failed",
                            "E3003"
                        ));
                        return new ConstantValue(0);
                    }

                    // Get pointer to field: targetPtr + offset
                    var fieldType2 = accessStruct.GetFieldType(fieldAccess.FieldName) ?? TypeRegistry.Never;
                    var fieldPointer = new LocalValue($"field_ptr_{_tempCounter++}", new ReferenceType(fieldType2));
                    var fieldGepInst = new GetElementPtrInstruction(currentPtr, fieldByteOffset, fieldPointer);
                    _currentBlock.Instructions.Add(fieldGepInst);

                    // Load value from field
                    var fieldLoadResult = new LocalValue($"field_load_{_tempCounter++}", fieldType2);
                    var fieldLoadInst = new LoadInstruction(fieldPointer, fieldLoadResult);
                    _currentBlock.Instructions.Add(fieldLoadInst);

                    return fieldLoadResult;
                }

            case ArrayLiteralExpressionNode arrayLiteral:
                {
                    // Get array type from type solver
                    var arrayLitType = arrayLiteral.Type as ArrayType;
                    if (arrayLitType == null)
                    {
                        _diagnostics.Add(Diagnostic.Error(
                            "cannot determine array type",
                            arrayLiteral.Span,
                            "type checking failed",
                            "E3004"
                        ));
                        return new ConstantValue(0);
                    }

                    // Create global constant for array literal (like string literals)
                    var arrayId = _compilation.AllocateStringId(); // Reuse the string ID counter for simplicity
                    var arrayGlobalName = $"LA{arrayId}"; // LA = Literal Array

                    // Collect element values
                    Value[] elementValues;
                    if (arrayLiteral.IsRepeatSyntax)
                    {
                        // Repeat syntax: [value; count]
                        var repeatValue = LowerExpression(arrayLiteral.RepeatValue!);

                        // For constants, we can create the array directly
                        if (repeatValue is ConstantValue constVal)
                        {
                            elementValues = new Value[arrayLiteral.RepeatCount!.Value];
                            for (var i = 0; i < arrayLiteral.RepeatCount.Value; i++)
                            {
                                elementValues[i] = constVal;
                            }
                        }
                        else
                        {
                            // Non-constant repeat values not supported in array literals
                            _diagnostics.Add(Diagnostic.Error(
                                "array literal with repeat syntax must have constant value",
                                arrayLiteral.Span,
                                "use a constant expression",
                                "E3005"
                            ));
                            return new ConstantValue(0);
                        }
                    }
                    else
                    {
                        // Regular array literal: [elem1, elem2, ...]
                        elementValues = new Value[arrayLiteral.Elements!.Count];
                        for (var i = 0; i < arrayLiteral.Elements.Count; i++)
                        {
                            var elemValue = LowerExpression(arrayLiteral.Elements[i]);

                            // Array literals must contain constant values
                            if (elemValue is not ConstantValue)
                            {
                                _diagnostics.Add(Diagnostic.Error(
                                    "array literal elements must be constant values",
                                    arrayLiteral.Elements[i].Span,
                                    "use a constant expression",
                                    "E3006"
                                ));
                                return new ConstantValue(0);
                            }

                            elementValues[i] = elemValue;
                        }
                    }

                    // Create array constant value
                    var arrayLitConst = new ArrayConstantValue(arrayLitType, elementValues);

                    // Create global (type will be &[T; N])
                    var arrayGlobal = new GlobalValue(arrayGlobalName, arrayLitConst);

                    // Register in function globals
                    _currentFunction.Globals.Add(arrayGlobal);

                    // Return the global - it's a pointer to the array
                    return arrayGlobal;
                }

            case IndexExpressionNode indexExpr:
                {
                    // Check if type checker resolved this to an op_index function call
                    if (indexExpr.ResolvedIndexFunction != null)
                    {
                        var baseValue = LowerExpression(indexExpr.Base);
                        var indexValue = LowerExpression(indexExpr.Index);

                        // Call op_index function
                        var resolvedFunc = indexExpr.ResolvedIndexFunction;

                        // Check if the first parameter expects a reference or value
                        var firstParamType = resolvedFunc.Parameters[0].ResolvedType?.Prune();
                        var firstParamExpectsRef = firstParamType is ReferenceType;

                        Value baseArg;
                        if (firstParamExpectsRef)
                        {
                            // op_index expects &T - lift to reference if needed
                            if (baseValue is LocalValue lv && lv.Type is ReferenceType)
                            {
                                // Already a reference
                                baseArg = baseValue;
                            }
                            else
                            {
                                // Need to take address - store to temp and get address
                                var baseType = indexExpr.Base.Type!;
                                var tempPtr = new LocalValue($"index_base_{_tempCounter++}", new ReferenceType(baseType));
                                var allocaInst = new AllocaInstruction(baseType, baseType.Size, tempPtr);
                                _currentBlock.Instructions.Add(allocaInst);
                                var storePtrInst = new StorePointerInstruction(tempPtr, baseValue);
                                _currentBlock.Instructions.Add(storePtrInst);
                                baseArg = tempPtr;
                            }
                        }
                        else
                        {
                            // op_index expects value T - dereference if needed
                            if (baseValue is LocalValue lv2 && lv2.Type is ReferenceType refType)
                            {
                                var derefResult = new LocalValue($"index_deref_{_tempCounter++}", refType.InnerType);
                                var derefLoadInst = new LoadInstruction(baseValue, derefResult);
                                _currentBlock.Instructions.Add(derefLoadInst);
                                baseArg = derefResult;
                            }
                            else
                            {
                                baseArg = baseValue;
                            }
                        }

                        // Collect parameter types from resolved function
                        var opIndexParamTypes = new List<FType>();
                        foreach (var param in resolvedFunc.Parameters)
                        {
                            var paramType = param.ResolvedType ??
                                throw new InvalidOperationException($"Parameter '{param.Name}' has no resolved type");
                            opIndexParamTypes.Add(paramType);
                        }

                        var returnType = indexExpr.Type ?? TypeRegistry.Never;
                        var resultValue = new LocalValue($"index_call_{_tempCounter++}", returnType);
                        var opIndexCall = new CallInstruction("op_index", [baseArg, indexValue], resultValue);
                        opIndexCall.CalleeParamTypes = opIndexParamTypes;
                        opIndexCall.IsForeignCall = (resolvedFunc.Modifiers & FunctionModifiers.Foreign) != 0;
                        _currentBlock.Instructions.Add(opIndexCall);

                        return resultValue;
                    }

                    // Fallback: built-in array indexing
                    var baseValueFallback = LowerExpression(indexExpr.Base);
                    var indexValueFallback = LowerExpression(indexExpr.Index);
                    var baseArrayType = indexExpr.Base.Type;

                    if (baseArrayType is ArrayType arrayTypeForIndex)
                    {
                        // Array indexing: arr[i]
                        var elemSize = GetTypeSize(arrayTypeForIndex.ElementType);

                        // Calculate offset: index * element_size
                        var offsetTemp = new LocalValue($"offset_{_tempCounter++}", TypeRegistry.USize);
                        var offsetInst = new BinaryInstruction(BinaryOp.Multiply, indexValueFallback,
                            new ConstantValue(elemSize) { Type = TypeRegistry.I32 }, offsetTemp);
                        _currentBlock.Instructions.Add(offsetInst);

                        // Calculate element address: base + offset
                        var indexElemPtr = new LocalValue($"index_ptr_{_tempCounter++}", new ReferenceType(arrayTypeForIndex.ElementType));
                        var indexGepInst = new GetElementPtrInstruction(baseValueFallback, offsetTemp, indexElemPtr);
                        _currentBlock.Instructions.Add(indexGepInst);

                        // Load value from element
                        var indexLoadResult = new LocalValue($"index_load_{_tempCounter++}", arrayTypeForIndex.ElementType);
                        var indexLoadInst = new LoadInstruction(indexElemPtr, indexLoadResult);
                        _currentBlock.Instructions.Add(indexLoadInst);

                        return indexLoadResult;
                    }

                    if (baseArrayType is StructType sliceTypeForIndex && TypeRegistry.IsSlice(sliceTypeForIndex))
                    {
                        // Slice indexing without op_index - should not happen if stdlib is loaded
                        _diagnostics.Add(Diagnostic.Error(
                            "slice indexing requires op_index function",
                            indexExpr.Span,
                            "ensure core.slice is imported",
                            "E3005"
                        ));
                        return new ConstantValue(0);
                    }

                    _diagnostics.Add(Diagnostic.Error(
                        "cannot index non-array type",
                        indexExpr.Span,
                        "type checking failed",
                        "E3006"
                    ));
                    return new ConstantValue(0);
                }

            default:
                throw new Exception($"Unknown expression type: {expression.GetType().Name}");
        }
    }

    /// <summary>
    /// Lowers indexed assignment: expr[index] = value
    /// For slices/custom types with op_set_index: calls op_set_index(&amp;base, index, value)
    /// For arrays: uses native pointer arithmetic and store
    /// </summary>
    private Value LowerIndexedAssignment(AssignmentExpressionNode assignment, IndexExpressionNode indexTarget)
    {
        var assignValue = LowerExpression(assignment.Value);

        // Check if type checker resolved this to an op_set_index function call
        if (indexTarget.ResolvedSetIndexFunction != null)
        {
            var baseValue = LowerExpression(indexTarget.Base);
            var indexValue = LowerExpression(indexTarget.Index);

            // Call op_set_index function
            var resolvedFunc = indexTarget.ResolvedSetIndexFunction;

            // Check if the first parameter expects a reference or value
            var firstParamType = resolvedFunc.Parameters[0].ResolvedType?.Prune();
            var firstParamExpectsRef = firstParamType is ReferenceType;

            Value baseArg;
            if (firstParamExpectsRef)
            {
                // op_set_index expects &T - lift to reference if needed
                if (baseValue is LocalValue lv && lv.Type is ReferenceType)
                {
                    baseArg = baseValue;
                }
                else
                {
                    var baseType = indexTarget.Base.Type!;
                    var tempPtr = new LocalValue($"set_index_base_{_tempCounter++}", new ReferenceType(baseType));
                    var allocaInst = new AllocaInstruction(baseType, baseType.Size, tempPtr);
                    _currentBlock.Instructions.Add(allocaInst);
                    var storePtrInst = new StorePointerInstruction(tempPtr, baseValue);
                    _currentBlock.Instructions.Add(storePtrInst);
                    baseArg = tempPtr;
                }
            }
            else
            {
                // op_set_index expects value T - dereference if needed
                if (baseValue is LocalValue lv2 && lv2.Type is ReferenceType refType)
                {
                    var derefResult = new LocalValue($"set_index_deref_{_tempCounter++}", refType.InnerType);
                    var loadInst = new LoadInstruction(baseValue, derefResult);
                    _currentBlock.Instructions.Add(loadInst);
                    baseArg = derefResult;
                }
                else
                {
                    baseArg = baseValue;
                }
            }

            var opSetIndexParamTypes = new List<FType>();
            foreach (var param in resolvedFunc.Parameters)
            {
                var paramType = param.ResolvedType ??
                    throw new InvalidOperationException($"Parameter '{param.Name}' has no resolved type");
                opSetIndexParamTypes.Add(paramType);
            }

            var returnType = resolvedFunc.ResolvedReturnType ?? TypeRegistry.Void;
            var resultValue = new LocalValue($"set_index_call_{_tempCounter++}", returnType);
            var opSetIndexCall = new CallInstruction("op_set_index", [baseArg, indexValue, assignValue], resultValue);
            opSetIndexCall.CalleeParamTypes = opSetIndexParamTypes;
            opSetIndexCall.IsForeignCall = (resolvedFunc.Modifiers & FunctionModifiers.Foreign) != 0;
            _currentBlock.Instructions.Add(opSetIndexCall);

            return assignValue;
        }

        // Built-in array indexing
        var baseValueFallback = LowerExpression(indexTarget.Base);
        var indexValueFallback = LowerExpression(indexTarget.Index);
        var baseArrayType = indexTarget.Base.Type;

        if (baseArrayType is ArrayType arrayType)
        {
            var elemSize = GetTypeSize(arrayType.ElementType);

            // Calculate offset: index * element_size
            var offsetTemp = new LocalValue($"set_offset_{_tempCounter++}", TypeRegistry.USize);
            var offsetInst = new BinaryInstruction(BinaryOp.Multiply, indexValueFallback,
                new ConstantValue(elemSize) { Type = TypeRegistry.I32 }, offsetTemp);
            _currentBlock.Instructions.Add(offsetInst);

            // Calculate element address: base + offset
            var elemPtr = new LocalValue($"set_index_ptr_{_tempCounter++}", new ReferenceType(arrayType.ElementType));
            var gepInst = new GetElementPtrInstruction(baseValueFallback, offsetTemp, elemPtr);
            _currentBlock.Instructions.Add(gepInst);

            // Store value to element
            var storeInst = new StorePointerInstruction(elemPtr, assignValue);
            _currentBlock.Instructions.Add(storeInst);

            return assignValue;
        }

        if (baseArrayType is StructType sliceType && TypeRegistry.IsSlice(sliceType))
        {
            // Slice set without op_set_index - should not happen if stdlib is loaded
            _diagnostics.Add(Diagnostic.Error(
                "slice indexed assignment requires op_set_index function",
                indexTarget.Span,
                "ensure core.slice is imported",
                "E3007"
            ));
            return assignValue;
        }

        _diagnostics.Add(Diagnostic.Error(
            "cannot index-assign to non-array type",
            indexTarget.Span,
            "type checking failed",
            "E3008"
        ));
        return assignValue;
    }

    private int GetTypeSize(FType type)
    {
        return type.Size;
    }

    private Value GetVariablePointer(IdentifierExpressionNode id, AssignmentExpressionNode assignment)
    {
        if (!_locals.TryGetValue(id.Name, out var targetPtr))
        {
            _diagnostics.Add(Diagnostic.Error(
                $"cannot assign to `{id.Name}` because it is not declared",
                assignment.Span,
                "declare the variable with `let` first",
                "E3010"
            ));
            // Return a dummy pointer to avoid cascading errors
            return new LocalValue("error", new ReferenceType(TypeRegistry.Never));
        }

        return targetPtr;
    }

    private Value GetFieldPointer(MemberAccessExpressionNode memberAccess)
    {
        // Get struct type from the target expression
        var targetValue = LowerExpression(memberAccess.Target);
        var targetSemanticType = memberAccess.Target.Type;

        // Auto-dereference: if AutoDerefCount > 1, we need to dereference intermediate pointers
        // AutoDerefCount=0: struct direct access (already a struct value)
        // AutoDerefCount=1: &Struct - single pointer, no extra dereference needed (GEP handles it)
        // AutoDerefCount=2: &&Struct - need to load once to get &Struct, then GEP
        // AutoDerefCount=N: need to load N-1 times
        var currentPtr = targetValue;
        var currentType = targetSemanticType;
        for (int i = 0; i < memberAccess.AutoDerefCount - 1; i++)
        {
            // Dereference to get the next pointer level
            if (currentType is ReferenceType refType)
            {
                var innerType = refType.InnerType;
                var loadResult = new LocalValue($"autoderef_{_tempCounter++}", innerType);
                var loadInst = new LoadInstruction(currentPtr, loadResult);
                _currentBlock.Instructions.Add(loadInst);
                currentPtr = loadResult;
                currentType = innerType;
            }
        }

        // Find the struct type by unwrapping references
        var structTypeForAccess = currentType;
        while (structTypeForAccess is ReferenceType rt)
        {
            structTypeForAccess = rt.InnerType;
        }
        var accessStruct = structTypeForAccess as StructType;

        if (accessStruct == null)
        {
            _diagnostics.Add(Diagnostic.Error(
                "cannot access field on non-struct type",
                memberAccess.Span,
                "type checking failed",
                "E3002"
            ));
            return new LocalValue("error", new ReferenceType(TypeRegistry.Never));
        }

        // Calculate field offset
        var fieldByteOffset = accessStruct.GetFieldOffset(memberAccess.FieldName);
        if (fieldByteOffset == -1)
        {
            _diagnostics.Add(Diagnostic.Error(
                $"field `{memberAccess.FieldName}` not found",
                memberAccess.Span,
                "type checking failed",
                "E3003"
            ));
            return new LocalValue("error", new ReferenceType(TypeRegistry.Never));
        }

        // Get pointer to field: targetPtr + offset
        var fieldType = accessStruct.GetFieldType(memberAccess.FieldName) ?? TypeRegistry.Never;
        var fieldPointer = new LocalValue($"field_ptr_{_tempCounter++}", new ReferenceType(fieldType));
        var fieldGepInst = new GetElementPtrInstruction(currentPtr, fieldByteOffset, fieldPointer);
        _currentBlock.Instructions.Add(fieldGepInst);

        return fieldPointer;
    }

    private Value LowerIfExpression(IfExpressionNode ifExpr)
    {
        var condition = LowerExpression(ifExpr.Condition);

        var thenBlock = CreateBlock("if_then");
        var elseBlock = ifExpr.ElseBranch != null ? CreateBlock("if_else") : null;
        var mergeBlock = CreateBlock("if_merge");

        // Determine result type from then branch (type checker ensures both branches have compatible types)
        // We need to peek at the then branch type to allocate the phi variable
        var thenType = ifExpr.ThenBranch.Type;
        var isVoidResult = thenType == null || thenType == TypeRegistry.Void || thenType == TypeRegistry.Never;

        // For non-void if-expressions, allocate a phi result variable BEFORE branching
        // Both branches will store to this same variable (simulating a phi node)
        LocalValue? phiResult = null;
        LocalValue? phiResultPtr = null;
        if (!isVoidResult && ifExpr.ElseBranch != null)
        {
            phiResult = new LocalValue($"if_phi_{_tempCounter++}", thenType!);
            phiResultPtr = new LocalValue($"if_phi_ptr_{_tempCounter}", new ReferenceType(thenType!));
            var phiAlloca = new AllocaInstruction(thenType!, thenType!.Size, phiResultPtr);
            _currentBlock.Instructions.Add(phiAlloca);
        }

        // Branch to then or else
        _currentBlock.Instructions.Add(new BranchInstruction(condition, thenBlock, elseBlock ?? mergeBlock));

        // Lower then branch
        _currentBlock = thenBlock;
        var thenValue = LowerExpression(ifExpr.ThenBranch);

        // Store result to phi variable if non-void
        if (phiResultPtr != null)
        {
            _currentBlock.Instructions.Add(new StorePointerInstruction(phiResultPtr, thenValue));
        }
        _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));

        // Lower else branch if it exists
        if (ifExpr.ElseBranch != null && elseBlock != null)
        {
            _currentBlock = elseBlock;
            var elseValue = LowerExpression(ifExpr.ElseBranch);

            // Store result to phi variable if non-void
            if (phiResultPtr != null)
            {
                _currentBlock.Instructions.Add(new StorePointerInstruction(phiResultPtr, elseValue));
            }
            _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));
        }

        // Continue in merge block
        _currentBlock = mergeBlock;

        // Load and return the phi result, or a void constant if the if has void type
        if (phiResultPtr != null && phiResult != null)
        {
            _currentBlock.Instructions.Add(new LoadInstruction(phiResultPtr, phiResult));
            return phiResult;
        }
        else
            return new ConstantValue(0) { Type = TypeRegistry.Void };
    }

    private Value LowerBlockExpression(BlockExpressionNode blockExpr)
    {
        // Push a new defer scope for this block
        _deferStack.Push([]);

        foreach (var stmt in blockExpr.Statements) LowerStatement(stmt);

        Value result;
        if (blockExpr.TrailingExpression != null)
            result = LowerExpression(blockExpr.TrailingExpression);
        else
            // Block with no trailing expression returns unit/void (use 0 for now)
            result = new ConstantValue(0);

        // Emit deferred statements at block end (in LIFO order)
        EmitDeferredStatements();

        // Pop the defer scope
        _deferStack.Pop();

        return result;
    }

    private void LowerForLoop(ForLoopNode forLoop)
    {
        // Use iterator protocol lowered via iter/next functions.
        // TypeChecker has already validated and recorded the iterator and element types.
        var iterableType = forLoop.IterableExpression.Type;

        // If type checking failed for this loop, skip lowering – diagnostics are already emitted.
        if (forLoop.IteratorType == null || forLoop.ElementType == null || iterableType == null || forLoop.NextResultOptionType == null)
            return;

        var iteratorType = forLoop.IteratorType;
        var optionType = forLoop.NextResultOptionType;
        var elementType = forLoop.ElementType;

        // Create loop blocks
        var condBlock = CreateBlock("for_cond");
        var bodyBlock = CreateBlock("for_body");
        var exitBlock = CreateBlock("for_exit");

        // 1. Lower iterable expression
        var iterableValue = LowerExpression(forLoop.IterableExpression);

        // 2. Call iter(&iterable) -> IteratorStruct
        var iterResult = new LocalValue($"iter_{_tempCounter++}", iteratorType);
        var iterCall = new CallInstruction("iter", new List<Value> { iterableValue }, iterResult);
        // iter has signature: fn iter(&T) IteratorState
        iterCall.CalleeParamTypes = new List<FType> { new ReferenceType(iterableType) };
        _currentBlock.Instructions.Add(iterCall);

        // 3. Allocate iterator state on stack and store the initial iterator value
        var iteratorPtr = new LocalValue($"iter_ptr_{_tempCounter++}", new ReferenceType(iteratorType));
        var iteratorAlloca = new AllocaInstruction(iteratorType, iteratorType.Size, iteratorPtr);
        _currentBlock.Instructions.Add(iteratorAlloca);
        _currentBlock.Instructions.Add(new StorePointerInstruction(iteratorPtr, iterResult));

        // 4. Allocate loop variable on stack and register in locals
        var loopVarUniqueName = GetUniqueVariableName(forLoop.IteratorVariable);
        var loopVarPtr = new LocalValue(loopVarUniqueName, new ReferenceType(elementType));
        var loopVarAlloca = new AllocaInstruction(elementType, elementType.Size, loopVarPtr);
        _currentBlock.Instructions.Add(loopVarAlloca);
        _locals[forLoop.IteratorVariable] = loopVarPtr;

        // Jump to condition block
        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // 5. loop_cond: call next(&iterator), check has_value
        _currentBlock = condBlock;

        var nextResult = new LocalValue($"next_{_tempCounter++}", optionType);
        var nextCall = new CallInstruction("next", new List<Value> { iteratorPtr }, nextResult);
        // next has signature: fn next(&IteratorState) E?
        nextCall.CalleeParamTypes = new List<FType> { new ReferenceType(iteratorType) };
        _currentBlock.Instructions.Add(nextCall);

        // Load has_value field
        var hasValueOffset = optionType.GetFieldOffset("has_value");
        var hasValuePtr = new LocalValue($"has_value_ptr_{_tempCounter++}", new ReferenceType(TypeRegistry.Bool));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(
            nextResult,
            new ConstantValue(hasValueOffset) { Type = TypeRegistry.USize },
            hasValuePtr));

        var hasValue = new LocalValue($"has_value_{_tempCounter++}", TypeRegistry.Bool);
        _currentBlock.Instructions.Add(new LoadInstruction(hasValuePtr, hasValue));

        // Branch based on has_value
        _currentBlock.Instructions.Add(new BranchInstruction(hasValue, bodyBlock, exitBlock));

        // 6. loop_body: extract value, bind loop variable, execute body, then jump back to cond
        _currentBlock = bodyBlock;

        _loopStack.Push(new LoopContext(condBlock, exitBlock));

        // Extract value field from Option
        var valueFieldType = optionType.GetFieldType("value") ?? elementType;
        var valueOffset = optionType.GetFieldOffset("value");
        var valuePtr = new LocalValue($"value_ptr_{_tempCounter++}", new ReferenceType(valueFieldType));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(
            nextResult,
            new ConstantValue(valueOffset) { Type = TypeRegistry.USize },
            valuePtr));

        var loopValue = new LocalValue($"{forLoop.IteratorVariable}_val_{_tempCounter++}", valueFieldType);
        _currentBlock.Instructions.Add(new LoadInstruction(valuePtr, loopValue));

        // Store into loop variable's stack slot
        _currentBlock.Instructions.Add(new StorePointerInstruction(loopVarPtr, loopValue));

        // Lower loop body expression
        LowerExpression(forLoop.Body);
        _loopStack.Pop();

        // At end of body, jump back to condition
        _currentBlock.Instructions.Add(new JumpInstruction(condBlock));

        // 7. loop_exit: set as current block; no additional work needed
        _currentBlock = exitBlock;
    }

    /// <summary>
    /// Lower a RangeExpressionNode (a..b) to a Range struct construction.
    /// Creates: .{ start = a, end = b } as a Range struct.
    /// </summary>
    private Value LowerRangeToStruct(RangeExpressionNode rangeExpr)
    {
        // Get the Range struct type from type checker
        var rangeType = rangeExpr.Type as StructType;
        if (rangeType == null)
        {
            _diagnostics.Add(Diagnostic.Error(
                "range expression has invalid type",
                rangeExpr.Span,
                "expected Range struct type",
                "E3008"
            ));
            return new ConstantValue(0);
        }

        // Lower start and end expressions
        var startValue = LowerExpression(rangeExpr.Start);
        var endValue = LowerExpression(rangeExpr.End);

        // Allocate Range struct on stack
        var rangePtr = new LocalValue($"_range_ptr_{_tempCounter++}", new ReferenceType(rangeType));
        _currentBlock.Instructions.Add(new AllocaInstruction(
            rangeType, rangeType.Size, rangePtr));

        // Set start field
        var startFieldOffset = rangeType.GetFieldOffset("start");
        var startFieldPtr = new LocalValue($"_start_ptr_{_tempCounter++}", new ReferenceType(startValue.Type!));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(
            rangePtr, new ConstantValue(startFieldOffset) { Type = TypeRegistry.USize },
            startFieldPtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(startFieldPtr, startValue));

        // Set end field
        var endFieldOffset = rangeType.GetFieldOffset("end");
        var endFieldPtr = new LocalValue($"_end_ptr_{_tempCounter++}", new ReferenceType(endValue.Type!));
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(
            rangePtr, new ConstantValue(endFieldOffset) { Type = TypeRegistry.USize },
            endFieldPtr));
        _currentBlock.Instructions.Add(new StorePointerInstruction(endFieldPtr, endValue));

        // Load the Range value
        var rangeValue = new LocalValue($"_range_{_tempCounter++}", rangeType);
        _currentBlock.Instructions.Add(new LoadInstruction(rangePtr, rangeValue));

        return rangeValue;
    }

    /// <summary>
    /// Copy struct fields from one location to another using memcpy.
    /// </summary>
    private void CopyStruct(Value destPtr, Value srcPtr, StructType structType)
    {
        // Use memcpy to copy the entire struct
        var sizeVal = new ConstantValue(structType.Size) { Type = TypeRegistry.USize };
        var memcpyResult = new LocalValue($"_unused_{_tempCounter++}", TypeRegistry.Void);

        var memcpyCall = new CallInstruction("memcpy",
            new List<Value> { destPtr, srcPtr, sizeVal },
            memcpyResult);
        memcpyCall.IsForeignCall = true;

        _currentBlock.Instructions.Add(memcpyCall);
    }

    /// <summary>
    /// Emit memcpy to copy array data from a global to a local.
    /// </summary>
    private void EmitArrayMemcpy(Value dest, GlobalValue src, int size)
    {
        var memcpyResult = new LocalValue($"memcpy_{_tempCounter++}", TypeRegistry.Void);
        var sizeValue = new ConstantValue(size) { Type = TypeRegistry.USize };

        var memcpyCall = new CallInstruction(
            "memcpy",
            new List<Value> { dest, src, sizeValue },
            memcpyResult)
        {
            IsForeignCall = true
        };
        _currentBlock.Instructions.Add(memcpyCall);
    }

    /// <summary>
    /// Zero-initialize memory using memset(ptr, 0, size).
    /// Used for uninitialized arrays and structs.
    /// </summary>
    private void ZeroInitialize(Value ptr, int sizeInBytes)
    {
        // memset(ptr, 0, size)
        var zeroValue = new ConstantValue(0) { Type = TypeRegistry.U8 };
        var sizeValue = new ConstantValue(sizeInBytes) { Type = TypeRegistry.USize };
        var memsetResult = new LocalValue($"_unused_{_tempCounter++}", TypeRegistry.Void);

        var memsetCall = new CallInstruction("memset",
            new List<Value> { ptr, zeroValue, sizeValue },
            memsetResult)
        {
            IsForeignCall = true // memset is a C standard library function
        };

        _currentBlock.Instructions.Add(memsetCall);
    }

    private Value LowerStructLiteral(IReadOnlyList<(string FieldName, ExpressionNode Value)> fields,
        StructType structType,
        SourceSpan span)
    {
        var allocaResult = new LocalValue($"alloca_{_tempCounter++}", new ReferenceType(structType));
        var allocaInst = new AllocaInstruction(structType, structType.Size, allocaResult);
        _currentBlock.Instructions.Add(allocaInst);

        foreach (var (fieldName, fieldExpr) in fields)
        {
            var fieldType = structType.GetFieldType(fieldName);
            var fieldOffset = structType.GetFieldOffset(fieldName);
            if (fieldType == null || fieldOffset < 0)
            {
                _diagnostics.Add(Diagnostic.Error(
                    $"struct `{structType.Name}` does not have a field named `{fieldName}`",
                    span,
                    null,
                    "E3014"));
                continue;
            }

            var fieldValue = LowerExpression(fieldExpr);
            var fieldPtrResult = new LocalValue($"field_ptr_{_tempCounter++}", new ReferenceType(fieldType));
            var gepInst = new GetElementPtrInstruction(allocaResult, fieldOffset, fieldPtrResult);
            _currentBlock.Instructions.Add(gepInst);

            var storeInst = new StorePointerInstruction(fieldPtrResult, fieldValue);
            _currentBlock.Instructions.Add(storeInst);
        }

        var structValue = new LocalValue($"struct_val_{_tempCounter++}", structType);
        var loadInst = new LoadInstruction(allocaResult, structValue);
        _currentBlock.Instructions.Add(loadInst);
        return structValue;
    }

    private Value LowerNullLiteral(StructType optionType)
    {
        var allocaResult = new LocalValue($"alloca_{_tempCounter++}", new ReferenceType(optionType));
        var allocaInst = new AllocaInstruction(optionType, optionType.Size, allocaResult);
        _currentBlock.Instructions.Add(allocaInst);

        ZeroInitialize(allocaResult, optionType.Size);
        var falseValue = new ConstantValue(0) { Type = TypeRegistry.Bool };
        StoreStructField(allocaResult, optionType, "has_value", falseValue);

        var structValue = new LocalValue($"struct_val_{_tempCounter++}", optionType);
        var loadInst = new LoadInstruction(allocaResult, structValue);
        _currentBlock.Instructions.Add(loadInst);
        return structValue;
    }

    private Value LowerLiftToOption(Value innerValue, StructType optionType)
    {
        var allocaResult = new LocalValue($"alloca_{_tempCounter++}", new ReferenceType(optionType));
        var allocaInst = new AllocaInstruction(optionType, optionType.Size, allocaResult);
        _currentBlock.Instructions.Add(allocaInst);

        ZeroInitialize(allocaResult, optionType.Size);
        var trueValue = new ConstantValue(1) { Type = TypeRegistry.Bool };
        StoreStructField(allocaResult, optionType, "has_value", trueValue);
        StoreStructField(allocaResult, optionType, "value", innerValue);

        var structValue = new LocalValue($"struct_val_{_tempCounter++}", optionType);
        var loadInst = new LoadInstruction(allocaResult, structValue);
        _currentBlock.Instructions.Add(loadInst);
        return structValue;
    }

    private bool TryWriteSliceFromArray(Value destinationPtr, StructType structType, Value sourceValue)
    {
        if (!TypeRegistry.IsSlice(structType) && !TypeRegistry.IsString(structType))
            return false;

        if (sourceValue.Type is not ReferenceType { InnerType: ArrayType arrayType })
            return false;

        var elementPtrType = new ReferenceType(arrayType.ElementType);
        var elementPtrValue = new LocalValue($"slice_ptr_{_tempCounter++}", elementPtrType);
        var castInst = new CastInstruction(sourceValue, elementPtrType, elementPtrValue);
        _currentBlock.Instructions.Add(castInst);

        StoreStructField(destinationPtr, structType, "ptr", elementPtrValue);
        var lenValue = new ConstantValue(arrayType.Length) { Type = TypeRegistry.USize };
        StoreStructField(destinationPtr, structType, "len", lenValue);
        return true;
    }

    private void StoreStructField(Value destinationPtr, StructType structType, string fieldName, Value value)
    {
        if (destinationPtr.Type is not ReferenceType)
            return;

        var fieldType = structType.GetFieldType(fieldName) ?? TypeRegistry.Never;
        var fieldOffset = structType.GetFieldOffset(fieldName);
        if (fieldOffset < 0)
            return;

        var fieldPointer = new LocalValue($"struct_{fieldName}_ptr_{_tempCounter++}", new ReferenceType(fieldType));
        var fieldGep = new GetElementPtrInstruction(destinationPtr, fieldOffset, fieldPointer);
        _currentBlock.Instructions.Add(fieldGep);
        var storeInst = new StorePointerInstruction(fieldPointer, value);
        _currentBlock.Instructions.Add(storeInst);
    }

    private FType? GetExpressionType(ExpressionNode node) => node.Type;

    // ==================== Enum Construction Lowering ====================

    private Value LowerEnumConstruction(CallExpressionNode call, EnumType enumType)
    {
        // Parse variant name from call
        string variantName;
        if (call.FunctionName.Contains('.'))
        {
            var parts = call.FunctionName.Split('.');
            variantName = parts[1];
        }
        else
        {
            variantName = call.FunctionName;
        }

        // Find variant index
        int variantIndex = -1;
        (string VariantName, TypeBase? PayloadType)? variant = null;
        for (int i = 0; i < enumType.Variants.Count; i++)
        {
            if (enumType.Variants[i].VariantName == variantName)
            {
                variantIndex = i;
                variant = enumType.Variants[i];
                break;
            }
        }

        if (variantIndex == -1 || variant == null)
        {
            // Error - should have been caught in type checking
            _diagnostics.Add(Diagnostic.Error(
                $"variant `{variantName}` not found in enum `{enumType.Name}`",
                call.Span,
                null,
                "E3037"));
            return new LocalValue("error", enumType);
        }

        // 1. Allocate space for the enum on the stack
        var enumPtr = new LocalValue($"enum_{_tempCounter++}", new ReferenceType(enumType));
        var allocaInst = new AllocaInstruction(enumType, enumType.Size, enumPtr);
        _currentBlock.Instructions.Add(allocaInst);

        // 2. Get pointer to tag field (at offset from EnumType.GetTagOffset())
        var tagOffset = enumType.GetTagOffset();
        var tagPtr = new LocalValue($"tag_ptr_{_tempCounter++}", new ReferenceType(TypeRegistry.I32));
        var tagGep = new GetElementPtrInstruction(enumPtr, tagOffset, tagPtr);
        _currentBlock.Instructions.Add(tagGep);

        // 3. Store the variant tag value
        var tagValue = new ConstantValue((int)enumType.GetTagValue(variantIndex)) { Type = TypeRegistry.I32 };
        var tagStore = new StorePointerInstruction(tagPtr, tagValue);
        _currentBlock.Instructions.Add(tagStore);

        // 4. If variant has payload, store payload data
        if (variant.Value.PayloadType != null)
        {
            var payloadOffset = enumType.GetPayloadOffset(variantIndex);

            if (variant.Value.PayloadType is StructType st && st.Name.Contains("_payload"))
            {
                // Multiple payloads - store each field
                for (int i = 0; i < call.Arguments.Count && i < st.Fields.Count; i++)
                {
                    var argValue = LowerExpression(call.Arguments[i]);
                    var fieldOffset = st.GetFieldOffset(st.Fields[i].Name);
                    var fieldPtr = new LocalValue($"payload_field_ptr_{_tempCounter++}", new ReferenceType(st.Fields[i].Type));
                    var fieldGep = new GetElementPtrInstruction(enumPtr, payloadOffset + fieldOffset, fieldPtr);
                    _currentBlock.Instructions.Add(fieldGep);
                    var fieldStore = new StorePointerInstruction(fieldPtr, argValue);
                    _currentBlock.Instructions.Add(fieldStore);
                }
            }
            else
            {
                // Single payload
                var argValue = LowerExpression(call.Arguments[0]);
                var payloadPtr = new LocalValue($"payload_ptr_{_tempCounter++}", new ReferenceType(variant.Value.PayloadType));
                var payloadGep = new GetElementPtrInstruction(enumPtr, payloadOffset, payloadPtr);
                _currentBlock.Instructions.Add(payloadGep);
                var payloadStore = new StorePointerInstruction(payloadPtr, argValue);
                _currentBlock.Instructions.Add(payloadStore);
            }
        }

        // 5. Load the enum value from the pointer
        var enumResult = new LocalValue($"enum_val_{_tempCounter++}", enumType);
        var loadInst = new LoadInstruction(enumPtr, enumResult);
        _currentBlock.Instructions.Add(loadInst);

        return enumResult;
    }

    // ==================== Match Expression Lowering ====================

    private Value LowerMatchExpression(MatchExpressionNode match)
    {
        // Get enum type from scrutinee and dereference flag from match node
        // If scrutinee is a reference type, unwrap it to get the inner enum type
        var scrutineeType = match.Scrutinee.Type;
        if (scrutineeType is ReferenceType rt)
            scrutineeType = rt.InnerType;

        var enumType = scrutineeType as EnumType;
        if (enumType == null)
        {
            _diagnostics.Add(Diagnostic.Error(
                "match expression not properly type-checked",
                match.Span,
                null,
                "E1001"));
            return new LocalValue("error", TypeRegistry.I32);
        }

        var needsDereference = match.NeedsDereference;
        var resultType = match.Type ?? TypeRegistry.Never;

        // Lower scrutinee
        var scrutineeValue = LowerExpression(match.Scrutinee);

        // If scrutinee is a reference, dereference it to get the enum value
        if (needsDereference)
        {
            var derefValue = new LocalValue($"match_deref_{_tempCounter++}", enumType);
            var loadInst = new LoadInstruction(scrutineeValue, derefValue);
            _currentBlock.Instructions.Add(loadInst);
            scrutineeValue = derefValue;
        }

        // Allocate space on stack to hold scrutinee (so we can get pointer to it)
        var scrutineePtr = new LocalValue($"match_scrutinee_ptr_{_tempCounter++}", new ReferenceType(enumType));
        var allocaInst = new AllocaInstruction(enumType, enumType.Size, scrutineePtr);
        _currentBlock.Instructions.Add(allocaInst);
        var storeScrutinee = new StorePointerInstruction(scrutineePtr, scrutineeValue);
        _currentBlock.Instructions.Add(storeScrutinee);

        // Get pointer to tag field
        var tagOffset = enumType.GetTagOffset();
        var tagPtr = new LocalValue($"match_tag_ptr_{_tempCounter++}", new ReferenceType(TypeRegistry.I32));
        var tagGep = new GetElementPtrInstruction(scrutineePtr, tagOffset, tagPtr);
        _currentBlock.Instructions.Add(tagGep);

        // Load the tag value
        var tagValue = new LocalValue($"match_tag_{_tempCounter++}", TypeRegistry.I32);
        var tagLoad = new LoadInstruction(tagPtr, tagValue);
        _currentBlock.Instructions.Add(tagLoad);

        // Allocate result variable on stack (before any branches)
        var resultPtr = new LocalValue($"match_result_ptr_{_tempCounter++}", new ReferenceType(resultType));
        var resultAlloca = new AllocaInstruction(resultType, resultType.Size, resultPtr);
        _currentBlock.Instructions.Add(resultAlloca);

        // Create blocks in the order they should be emitted:
        // 1. Arm blocks (executed bodies)
        var armBlocks = new List<BasicBlock>();
        for (int i = 0; i < match.Arms.Count; i++)
        {
            armBlocks.Add(CreateBlock($"match_arm_{i}"));
        }

        // 2. Check blocks (condition chain for arms 1..N, except first which uses current block)
        var checkBlocks = new List<BasicBlock>();
        for (int i = 0; i < match.Arms.Count - 1; i++)
        {
            checkBlocks.Add(CreateBlock($"match_check_{i}"));
        }

        // 3. Merge block (final, after all arms and checks)
        var mergeBlock = CreateBlock("match_merge");

        // Build check chain and arm blocks (forward iteration)
        for (int armIndex = 0; armIndex < match.Arms.Count; armIndex++)
        {
            var arm = match.Arms[armIndex];
            var armBlock = armBlocks[armIndex];

            // Determine what block to use for the check
            // First arm uses current block, others use their check block
            var checkBlock = armIndex == 0 ? _currentBlock : checkBlocks[armIndex - 1];

            // Emit the condition check
            _currentBlock = checkBlock;

            if (arm.Pattern is ElsePatternNode)
            {
                // Else always matches - unconditional jump to arm
                _currentBlock.Instructions.Add(new JumpInstruction(armBlock));
            }
            else if (arm.Pattern is EnumVariantPatternNode evpCheck)
            {
                // Find variant index
                string variantName = evpCheck.VariantName;
                int variantIndex = -1;
                for (int i = 0; i < enumType.Variants.Count; i++)
                {
                    if (enumType.Variants[i].VariantName == variantName)
                    {
                        variantIndex = i;
                        break;
                    }
                }

                // Compare tag with variant tag value
                var expectedTag = new ConstantValue((int)enumType.GetTagValue(variantIndex)) { Type = TypeRegistry.I32 };
                var comparison = new LocalValue($"match_cmp_{_tempCounter++}", TypeRegistry.Bool);
                var cmpInst = new BinaryInstruction(BinaryOp.Equal, tagValue, expectedTag, comparison);
                _currentBlock.Instructions.Add(cmpInst);

                // Determine the else target (next check or merge if last)
                var elseTarget = armIndex < match.Arms.Count - 1 ? checkBlocks[armIndex] : mergeBlock;
                _currentBlock.Instructions.Add(new BranchInstruction(comparison, armBlock, elseTarget));
            }

            // Fill in the arm block with pattern bindings and result expression
            _currentBlock = armBlock;

            // Bind pattern variables (if any)
            if (arm.Pattern is EnumVariantPatternNode evp)
            {
                // Find the variant
                string variantName = evp.VariantName;
                int variantIndex = -1;
                (string VariantName, TypeBase? PayloadType)? variant = null;
                for (int i = 0; i < enumType.Variants.Count; i++)
                {
                    if (enumType.Variants[i].VariantName == variantName)
                    {
                        variantIndex = i;
                        variant = enumType.Variants[i];
                        break;
                    }
                }

                // Extract payload if present
                if (variant.HasValue && variant.Value.PayloadType != null)
                {
                    var payloadOffset = enumType.GetPayloadOffset(variantIndex);

                    if (variant.Value.PayloadType is StructType st && st.Name.Contains("_payload"))
                    {
                        // Multiple fields
                        for (int i = 0; i < evp.SubPatterns.Count && i < st.Fields.Count; i++)
                        {
                            if (evp.SubPatterns[i] is VariablePatternNode vp)
                            {
                                var fieldOffset = st.GetFieldOffset(st.Fields[i].Name);
                                var fieldPtr = new LocalValue($"payload_field_{_tempCounter++}", new ReferenceType(st.Fields[i].Type));
                                var fieldGep = new GetElementPtrInstruction(scrutineePtr,
                                    payloadOffset + fieldOffset, fieldPtr);
                                _currentBlock.Instructions.Add(fieldGep);
                                // Make variable name unique per-arm to avoid C redefinition errors
                                var fieldValue = new LocalValue($"{vp.Name}_arm{armIndex}_{_tempCounter++}", st.Fields[i].Type);
                                var fieldLoad = new LoadInstruction(fieldPtr, fieldValue);
                                _currentBlock.Instructions.Add(fieldLoad);
                                _locals[vp.Name] = fieldPtr; // Store pointer for later access
                            }
                        }
                    }
                    else if (evp.SubPatterns.Count > 0 && evp.SubPatterns[0] is VariablePatternNode vp)
                    {
                        // Single field
                        var payloadPtr = new LocalValue($"payload_{_tempCounter++}", new ReferenceType(variant.Value.PayloadType));
                        var payloadGep = new GetElementPtrInstruction(scrutineePtr, payloadOffset, payloadPtr);
                        _currentBlock.Instructions.Add(payloadGep);
                        // Make variable name unique per-arm to avoid C redefinition errors
                        var payloadValue = new LocalValue($"{vp.Name}_arm{armIndex}_{_tempCounter++}", variant.Value.PayloadType);
                        var payloadLoad = new LoadInstruction(payloadPtr, payloadValue);
                        _currentBlock.Instructions.Add(payloadLoad);
                        _locals[vp.Name] = payloadPtr; // Store pointer for later access
                    }
                }
            }

            // Lower the arm expression and store to result pointer
            var armResultValue = LowerExpression(arm.ResultExpr);
            var storeResult = new StorePointerInstruction(resultPtr, armResultValue);
            _currentBlock.Instructions.Add(storeResult);

            // Jump to merge block
            _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));
        }

        // Continue in merge block
        _currentBlock = mergeBlock;

        // Load the result that was written by whichever arm executed
        var finalResult = new LocalValue($"match_result_{_tempCounter++}", resultType);
        var loadResult = new LoadInstruction(resultPtr, finalResult);
        _currentBlock.Instructions.Add(loadResult);

        return finalResult;
    }

    // ==================== Implicit Coercion Lowering ====================

    private Value LowerImplicitCoercion(ImplicitCoercionNode coercion)
    {
        // First lower the inner expression
        var innerValue = LowerExpression(coercion.Inner);
        var targetType = coercion.TargetType;

        // AstLowering trusts the types from TypeChecker.
        // We emit explicit CastInstructions for type conversions, letting the
        // backend decide whether actual code is needed (e.g., no-op for binary-compatible types).

        switch (coercion.Kind)
        {
            case CoercionKind.IntegerWidening:
                // Integer widening (including comptime_int hardening)
                // For comptime_int, emit a cast to materialize the concrete type
                // For same types, no cast needed
                if (innerValue.Type!.Equals(targetType))
                    return innerValue;
                {
                    var castResult = new LocalValue($"cast_{_tempCounter++}", targetType);
                    var castInst = new CastInstruction(innerValue, targetType, castResult);
                    _currentBlock.Instructions.Add(castInst);
                    return castResult;
                }

            case CoercionKind.ReinterpretCast:
                // Binary-compatible types: emit a cast instruction
                // The C backend will emit this as a simple cast that may be a no-op
                // Examples: String ↔ Slice(u8), [T; N] → Slice(T), Slice(T) → &T
                if (innerValue.Type!.Equals(targetType))
                    return innerValue;
                {
                    var castResult = new LocalValue($"reinterpret_{_tempCounter++}", targetType);
                    var castInst = new CastInstruction(innerValue, targetType, castResult);
                    _currentBlock.Instructions.Add(castInst);
                    return castResult;
                }

            case CoercionKind.Wrap:
                // T → Option(T): wrap value in Option struct
                if (targetType is StructType optionType && TypeRegistry.IsOption(optionType))
                {
                    // If wrapping comptime_int, emit a cast to harden first
                    var valueToWrap = innerValue;
                    if (innerValue.Type is ComptimeInt && optionType.TypeArguments.Count > 0)
                    {
                        var hardenResult = new LocalValue($"harden_{_tempCounter++}", optionType.TypeArguments[0]);
                        var hardenInst = new CastInstruction(innerValue, optionType.TypeArguments[0], hardenResult);
                        _currentBlock.Instructions.Add(hardenInst);
                        valueToWrap = hardenResult;
                    }
                    return LowerLiftToOption(valueToWrap, optionType);
                }
                // Fallback for other wrap types (future expansion)
                {
                    var castResult = new LocalValue($"wrap_{_tempCounter++}", targetType);
                    var castInst = new CastInstruction(innerValue, targetType, castResult);
                    _currentBlock.Instructions.Add(castInst);
                    return castResult;
                }

            default:
                // Should not happen - all coercion kinds are handled above
                throw new InvalidOperationException($"Unknown coercion kind: {coercion.Kind}");
        }
    }

    /// <summary>
    /// Lowers a short-circuit logical operator (and/or) using branching.
    /// </summary>
    private Value LowerShortCircuitLogical(BinaryExpressionNode binary)
    {
        var isAnd = binary.Operator == BinaryOperatorKind.And;
        var left = LowerExpression(binary.Left);

        // Allocate result on stack
        var resultPtr = new LocalValue($"logic_result_{_tempCounter++}", new ReferenceType(TypeRegistry.Bool));
        _currentBlock.Instructions.Add(new AllocaInstruction(TypeRegistry.Bool, TypeRegistry.Bool.Size, resultPtr));

        // Store short-circuit default: false for 'and', true for 'or'
        var defaultVal = new ConstantValue(isAnd ? 0 : 1) { Type = TypeRegistry.Bool };
        _currentBlock.Instructions.Add(new StorePointerInstruction(resultPtr, defaultVal));

        var rhsBlock = CreateBlock(isAnd ? "and_rhs" : "or_rhs");
        var mergeBlock = CreateBlock(isAnd ? "and_merge" : "or_merge");

        // For 'and': if LHS is true, evaluate RHS; else skip (result stays false)
        // For 'or':  if LHS is false, evaluate RHS; else skip (result stays true)
        if (isAnd)
            _currentBlock.Instructions.Add(new BranchInstruction(left, rhsBlock, mergeBlock));
        else
            _currentBlock.Instructions.Add(new BranchInstruction(left, mergeBlock, rhsBlock));

        // RHS block: evaluate right side and store
        _currentBlock = rhsBlock;
        var right = LowerExpression(binary.Right);
        _currentBlock.Instructions.Add(new StorePointerInstruction(resultPtr, right));
        _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));

        // Merge block: load and return result
        _currentBlock = mergeBlock;
        var result = new LocalValue($"logic_val_{_tempCounter++}", TypeRegistry.Bool);
        _currentBlock.Instructions.Add(new LoadInstruction(resultPtr, result));
        return result;
    }

    /// <summary>
    /// Lowers an operator function call (e.g., op_add for +, op_eq for ==).
    /// </summary>
    private Value LowerOperatorFunctionCall(BinaryExpressionNode binary, Value left, Value right)
    {
        var resolvedFunc = binary.ResolvedOperatorFunction!;
        var opFuncName = resolvedFunc.Name;

        // Collect parameter types from resolved function
        var paramTypes = new List<FType>();
        foreach (var param in resolvedFunc.Parameters)
        {
            var paramType = param.ResolvedType ??
                throw new InvalidOperationException($"Parameter '{param.Name}' has no resolved type");
            paramTypes.Add(paramType);
        }

        // Build argument list with casts if needed
        var args = new List<Value>();
        Value[] operands = [left, right];
        for (var i = 0; i < 2; i++)
        {
            var argVal = operands[i];
            var argType = i == 0 ? binary.Left.Type : binary.Right.Type;

            // Insert cast if argument type doesn't match parameter type but can coerce
            if (i < paramTypes.Count && argType != null && !argType.Equals(paramTypes[i]))
            {
                var argCastResult = new LocalValue($"cast_{_tempCounter++}", paramTypes[i]);
                var argCastInst = new CastInstruction(argVal, paramTypes[i], argCastResult);
                _currentBlock.Instructions.Add(argCastInst);
                args.Add(argCastResult);
            }
            else
            {
                args.Add(argVal);
            }
        }

        // When auto-deriving from op_cmp, the call returns the function's return type (Ord/i32),
        // not the expression type (bool). We compare the result against 0 afterward.
        var returnType = binary.CmpDerivedOperator != null
            ? resolvedFunc.ResolvedReturnType ?? TypeRegistry.I32
            : binary.Type ?? TypeRegistry.Never;
        var callResult = new LocalValue($"op_{_tempCounter++}", returnType);
        var callInst = new CallInstruction(opFuncName, args, callResult);
        callInst.CalleeParamTypes = paramTypes;
        callInst.IsForeignCall = (resolvedFunc.Modifiers & FunctionModifiers.Foreign) != 0;

        _currentBlock.Instructions.Add(callInst);

        // Auto-derived op_eq/op_ne: negate the complement's result
        if (binary.NegateOperatorResult)
        {
            var negResult = new LocalValue($"not_{_tempCounter++}", returnType);
            _currentBlock.Instructions.Add(new UnaryInstruction(UnaryOp.Not, callResult, negResult));
            return negResult;
        }

        // Auto-derived from op_cmp: extract tag from Ord enum, compare against 0
        if (binary.CmpDerivedOperator is { } cmpOp)
        {
            // op_cmp returns an Ord enum (naked enum with tag values -1, 0, 1).
            // Extract the tag field to get the underlying i32 value.
            var ordPtr = new LocalValue($"ord_ptr_{_tempCounter++}", new ReferenceType(returnType));
            _currentBlock.Instructions.Add(new AllocaInstruction(returnType, returnType.Size, ordPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(ordPtr, callResult));

            var tagPtr = new LocalValue($"ord_tag_ptr_{_tempCounter++}", new ReferenceType(TypeRegistry.I32));
            _currentBlock.Instructions.Add(new GetElementPtrInstruction(ordPtr, 0, tagPtr));

            var tagValue = new LocalValue($"ord_tag_{_tempCounter++}", TypeRegistry.I32);
            _currentBlock.Instructions.Add(new LoadInstruction(tagPtr, tagValue));

            var irOp = cmpOp switch
            {
                BinaryOperatorKind.LessThan => BinaryOp.LessThan,
                BinaryOperatorKind.GreaterThan => BinaryOp.GreaterThan,
                BinaryOperatorKind.LessThanOrEqual => BinaryOp.LessThanOrEqual,
                BinaryOperatorKind.GreaterThanOrEqual => BinaryOp.GreaterThanOrEqual,
                BinaryOperatorKind.Equal => BinaryOp.Equal,
                BinaryOperatorKind.NotEqual => BinaryOp.NotEqual,
                _ => throw new InvalidOperationException($"Unexpected CmpDerivedOperator: {cmpOp}")
            };
            var zero = new ConstantValue(0) { Type = TypeRegistry.I32 };
            var boolResult = new LocalValue($"cmp_{_tempCounter++}", TypeRegistry.Bool);
            _currentBlock.Instructions.Add(new BinaryInstruction(irOp, tagValue, zero, boolResult));
            return boolResult;
        }

        return callResult;
    }

    private Value LowerUnaryOperatorFunctionCall(UnaryExpressionNode unary, Value operand)
    {
        var resolvedFunc = unary.ResolvedOperatorFunction!;
        var opFuncName = OperatorFunctions.GetFunctionName(unary.Operator);

        var paramTypes = new List<FType>();
        foreach (var param in resolvedFunc.Parameters)
        {
            var paramType = param.ResolvedType ??
                throw new InvalidOperationException($"Parameter '{param.Name}' has no resolved type");
            paramTypes.Add(paramType);
        }

        var args = new List<Value>();
        var argType = unary.Operand.Type;

        if (paramTypes.Count > 0 && argType != null && !argType.Equals(paramTypes[0]))
        {
            var argCastResult = new LocalValue($"cast_{_tempCounter++}", paramTypes[0]);
            var argCastInst = new CastInstruction(operand, paramTypes[0], argCastResult);
            _currentBlock.Instructions.Add(argCastInst);
            args.Add(argCastResult);
        }
        else
        {
            args.Add(operand);
        }

        var returnType = unary.Type ?? TypeRegistry.Never;
        var callResult = new LocalValue($"op_{_tempCounter++}", returnType);
        var callInst = new CallInstruction(opFuncName, args, callResult);
        callInst.CalleeParamTypes = paramTypes;
        callInst.IsForeignCall = (resolvedFunc.Modifiers & FunctionModifiers.Foreign) != 0;

        _currentBlock.Instructions.Add(callInst);
        return callResult;
    }

    /// <summary>
    /// Lowers a null-coalescing expression (a ?? b) to an op_coalesce function call.
    /// </summary>
    private Value LowerCoalesceExpression(CoalesceExpressionNode coalesce)
    {
        var left = LowerExpression(coalesce.Left);
        var right = LowerExpression(coalesce.Right);

        var resolvedFunc = coalesce.ResolvedCoalesceFunction ??
            throw new InvalidOperationException("CoalesceExpressionNode has no resolved function");

        // Collect parameter types from resolved function
        var paramTypes = new List<FType>();
        foreach (var param in resolvedFunc.Parameters)
        {
            var paramType = param.ResolvedType ??
                throw new InvalidOperationException($"Parameter '{param.Name}' has no resolved type");
            paramTypes.Add(paramType);
        }

        // Build argument list with casts if needed
        var args = new List<Value>();
        Value[] operands = [left, right];
        for (var i = 0; i < 2; i++)
        {
            var argVal = operands[i];
            var argType = i == 0 ? coalesce.Left.Type : coalesce.Right.Type;

            // Insert cast if argument type doesn't match parameter type but can coerce
            if (i < paramTypes.Count && argType != null && !argType.Equals(paramTypes[i]))
            {
                var argCastResult = new LocalValue($"cast_{_tempCounter++}", paramTypes[i]);
                var argCastInst = new CastInstruction(argVal, paramTypes[i], argCastResult);
                _currentBlock.Instructions.Add(argCastInst);
                args.Add(argCastResult);
            }
            else
            {
                args.Add(argVal);
            }
        }

        var returnType = coalesce.Type ?? TypeRegistry.Never;
        var callResult = new LocalValue($"coalesce_{_tempCounter++}", returnType);
        var callInst = new CallInstruction("op_coalesce", args, callResult);
        callInst.CalleeParamTypes = paramTypes;
        callInst.IsForeignCall = (resolvedFunc.Modifiers & FunctionModifiers.Foreign) != 0;

        _currentBlock.Instructions.Add(callInst);
        return callResult;
    }

    /// <summary>
    /// Lowers a null-propagation expression (target?.field) to conditional branch.
    /// If target.has_value is true, result is Some(target.value.field); otherwise None.
    /// </summary>
    private Value LowerNullPropagationExpression(NullPropagationExpressionNode nullProp)
    {
        var resultType = nullProp.Type as StructType ??
            throw new InvalidOperationException("NullPropagationExpressionNode must have Option result type");

        // Allocate result storage
        var resultPtr = new LocalValue($"nullprop_result_{_tempCounter++}", new ReferenceType(resultType));
        var allocInst = new AllocaInstruction(resultType, resultType.Size, resultPtr);
        _currentBlock.Instructions.Add(allocInst);

        // Lower target expression
        var targetValue = LowerExpression(nullProp.Target);
        var targetType = nullProp.Target.Type as StructType ??
            throw new InvalidOperationException("NullPropagationExpressionNode target must be Option type");

        // If target is a value (not a pointer), we need to store it to get a pointer
        Value targetPtr;
        if (targetValue.Type is ReferenceType)
        {
            targetPtr = targetValue;
        }
        else
        {
            // Allocate temporary storage for target value and store it
            var tempPtr = new LocalValue($"nullprop_target_ptr_{_tempCounter++}", new ReferenceType(targetType));
            _currentBlock.Instructions.Add(new AllocaInstruction(targetType, targetType.Size, tempPtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(tempPtr, targetValue));
            targetPtr = tempPtr;
        }

        // Get pointer to target's has_value field
        var hasValuePtr = new LocalValue($"has_value_ptr_{_tempCounter++}", new ReferenceType(TypeRegistry.Bool));
        var hasValueOffset = new ConstantValue(0) { Type = TypeRegistry.USize }; // has_value is first field
        _currentBlock.Instructions.Add(new GetElementPtrInstruction(targetPtr, hasValueOffset, hasValuePtr));

        // Load has_value
        var hasValue = new LocalValue($"has_value_{_tempCounter++}", TypeRegistry.Bool);
        _currentBlock.Instructions.Add(new LoadInstruction(hasValuePtr, hasValue));

        // Create blocks
        var thenBlock = CreateBlock("nullprop_some");
        var elseBlock = CreateBlock("nullprop_none");
        var mergeBlock = CreateBlock("nullprop_merge");

        // Branch on has_value
        _currentBlock.Instructions.Add(new BranchInstruction(hasValue, thenBlock, elseBlock));

        // Then block: target has value, extract field and wrap in Some
        _currentBlock = thenBlock;
        {
            // Get pointer to target's value field
            var innerType = targetType.TypeArguments[0];
            var valueFieldOffset = targetType.GetFieldOffset("value");
            var valuePtr = new LocalValue($"value_ptr_{_tempCounter++}", new ReferenceType(innerType));
            _currentBlock.Instructions.Add(new GetElementPtrInstruction(targetPtr, new ConstantValue(valueFieldOffset) { Type = TypeRegistry.USize }, valuePtr));

            // If inner type is a struct, we need to get field from it
            if (innerType is StructType innerStruct)
            {
                var fieldOffset = innerStruct.GetFieldOffset(nullProp.MemberName);
                var fieldType = innerStruct.GetFieldType(nullProp.MemberName) ??
                    throw new InvalidOperationException($"Field {nullProp.MemberName} not found");

                var fieldPtr = new LocalValue($"field_ptr_{_tempCounter++}", new ReferenceType(fieldType));
                _currentBlock.Instructions.Add(new GetElementPtrInstruction(valuePtr, new ConstantValue(fieldOffset) { Type = TypeRegistry.USize }, fieldPtr));

                // Load field value
                var fieldValue = new LocalValue($"field_val_{_tempCounter++}", fieldType);
                _currentBlock.Instructions.Add(new LoadInstruction(fieldPtr, fieldValue));

                // Store has_value = true in result
                var resultHasValuePtr = new LocalValue($"result_has_value_ptr_{_tempCounter++}", new ReferenceType(TypeRegistry.Bool));
                _currentBlock.Instructions.Add(new GetElementPtrInstruction(resultPtr, new ConstantValue(0) { Type = TypeRegistry.USize }, resultHasValuePtr));
                _currentBlock.Instructions.Add(new StorePointerInstruction(resultHasValuePtr, new ConstantValue(1) { Type = TypeRegistry.Bool }));

                // Store field value in result.value
                var resultValueOffset = resultType.GetFieldOffset("value");
                var resultValuePtr = new LocalValue($"result_value_ptr_{_tempCounter++}", new ReferenceType(fieldType));
                _currentBlock.Instructions.Add(new GetElementPtrInstruction(resultPtr, new ConstantValue(resultValueOffset) { Type = TypeRegistry.USize }, resultValuePtr));
                _currentBlock.Instructions.Add(new StorePointerInstruction(resultValuePtr, fieldValue));
            }

            _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));
        }

        // Else block: target is null, result is None
        _currentBlock = elseBlock;
        {
            // Store has_value = false in result
            var resultHasValuePtr = new LocalValue($"result_has_value_ptr_{_tempCounter++}", new ReferenceType(TypeRegistry.Bool));
            _currentBlock.Instructions.Add(new GetElementPtrInstruction(resultPtr, new ConstantValue(0) { Type = TypeRegistry.USize }, resultHasValuePtr));
            _currentBlock.Instructions.Add(new StorePointerInstruction(resultHasValuePtr, new ConstantValue(0) { Type = TypeRegistry.Bool }));

            _currentBlock.Instructions.Add(new JumpInstruction(mergeBlock));
        }

        // Continue in merge block, load and return the result
        _currentBlock = mergeBlock;
        var finalResult = new LocalValue($"nullprop_final_{_tempCounter++}", resultType);
        _currentBlock.Instructions.Add(new LoadInstruction(resultPtr, finalResult));
        return finalResult;
    }

    private class LoopContext
    {
        public LoopContext(BasicBlock continueTarget, BasicBlock breakTarget)
        {
            ContinueTarget = continueTarget;
            BreakTarget = breakTarget;
        }

        public BasicBlock ContinueTarget { get; }
        public BasicBlock BreakTarget { get; }
    }
}
