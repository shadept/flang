## Make AstLowering stateless

1. Redesign type lifting:
- Make AstLowering stateless - it shouldn't need to query TypeChecker
- Add explicit CoercionNode or ImplicitCastNode to AST during type checking
- TypeChecker transforms return value → return <wrap_option>(value)
- AstLowering just lowers whatever nodes it sees
2. Benefits:
- Explicit AST representation of all type conversions
- Easier to debug (conversions visible in AST dump)
- Consistent handling across all contexts
- No reliance on type map lookups during lowering
3. Drawbacks:
- Larger change to architecture
- Need to update AST node types
- More complex type checker
