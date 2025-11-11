// Types have been moved to FLang.Core for better dependency management.
// This file provides namespace compatibility.

global using Type = FLang.Core.Type;
global using PrimitiveType = FLang.Core.PrimitiveType;
global using ComptimeIntType = FLang.Core.ComptimeIntType;
global using ComptimeFloatType = FLang.Core.ComptimeFloatType;
global using TypeVariable = FLang.Core.TypeVariable;
global using ReferenceType = FLang.Core.ReferenceType;
global using OptionType = FLang.Core.OptionType;
global using GenericType = FLang.Core.GenericType;
global using StructType = FLang.Core.StructType;
global using ArrayType = FLang.Core.ArrayType;
global using SliceType = FLang.Core.SliceType;
global using TypeRegistry = FLang.Core.TypeRegistry;

namespace FLang.Semantics;

// All type definitions have been moved to FLang.Core.Types