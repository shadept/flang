// Canonical error and warning codes the typer emits.
//
// The reporter formats every `Diagnostic` with one of these as the `code` field. Keeping them
// centralised here makes it cheap to audit the catalogue and update `docs/error-codes.md` in
// lock-step.

pub const E_TYPE_MISMATCH: String = "E2002"
pub const E_UNKNOWN_TYPE: String = "E2003"
pub const E_UNKNOWN_IDENT: String = "E2004"
pub const E_DUP_TYPE_DECL: String = "E2005"
pub const E_OCCURS_CHECK: String = "E2007"
pub const E_NO_OVERLOAD: String = "E2011"
pub const E_RETURN_MISMATCH: String = "E2071"
pub const E_ARITY_MISMATCH: String = "E2072"
pub const E_PRIM_CONSTRAINT: String = "E2102"
pub const E_DUP_VARIANT: String = "E2034"
pub const E_RECURSIVE_TYPE: String = "E2035"
pub const E_CYCLIC_ALIAS: String = "E2036"
pub const E_UNKNOWN_VARIANT: String = "E2037"
pub const E_UNINFERRED: String = "E2001"
pub const E_DUP_SIGNATURE: String = "E2103"
// A pattern form the front end cannot yet represent. Reported rather than ignored: an unrepresented
// pattern would otherwise be indistinguishable from a wildcard and silently match everything.
pub const E_UNSUPPORTED_PATTERN: String = "E2115"
// A generic struct constructed by name without its type arguments (`Pair { ... }` where `Pair` is
// `struct(T)`). Same code the reference checker uses for this shape.
pub const E_GENERIC_NEEDS_ARGS: String = "E2019"
// Indexing. `bool` is never a valid index; a type with neither `op_index_ref` nor `op_index` cannot
// be indexed at all. Branch joins: if/else branches, and match arms, that cannot agree on one type.
pub const E_BRANCH_MISMATCH: String = "E2074"
pub const E_ARM_MISMATCH: String = "E2075"
pub const E_BAD_INDEX_TYPE: String = "E2027"
pub const E_NOT_INDEXABLE: String = "E2028"
// RFC-009 postfix `?`: outside a function there is no return slot to early-return through; without
// a viable `op_try` the operand type does not participate in `?` at all. Same codes as the
// reference.
pub const E_TRY_OUTSIDE_FN: String = "E2090"
pub const E_NO_OP_TRY: String = "E2092"

// RFC-014 closures. Same codes as the reference: a capturing closure has an anonymous nominal type
// and cannot decay to a bare `fn` pointer (E2111); captures are by value and read-only (E2112);
// transitive captures across nested closures are not supported yet (E2113).
pub const E_CLOSURE_TO_FN: String = "E2111"
pub const E_ASSIGN_CAPTURE: String = "E2112"
pub const E_NESTED_CAPTURE: String = "E2113"

// Duplicate declarations the reference rejects at their declaration site: a struct field name twice
// (E2076), an enum tag value twice (E2048), a `let`/`const`/global re-declared in the same scope
// (E2005, shared with the duplicate-type code).
pub const E_DUP_FIELD: String = "E2076"
pub const E_DUP_TAG: String = "E2048"
// Assignment and initialization rules for `const` bindings.
pub const E_CONST_ASSIGN: String = "E2038"
pub const E_CONST_NO_INIT: String = "E2039"
// A field of a struct declared in ANOTHER module is read-only: the defining module owns its
// invariants (docs/spec.md scoped mutability).
pub const E_SCOPED_MUTABILITY: String = "E2114"
// A non-void function with no return on some path.
pub const E_MISSING_RETURN: String = "E2049"
// Match checking: scrutinee is not an enum (E2030), arms do not cover every variant (E2031), a
// variant pattern's payload arity is wrong (E2032).
pub const E_MATCH_NON_ENUM: String = "E2030"
pub const E_MATCH_NON_EXHAUSTIVE: String = "E2031"
pub const E_MATCH_ARITY: String = "E2032"
// Member access on a struct that has no such field.
pub const E_FIELD_NOT_FOUND: String = "E2014"
// `x.*` where `x` is neither a reference nor a type with `op_deref`.
pub const E_CANNOT_DEREF: String = "E2012"
// An explicit `as` cast between types with no defined conversion.
pub const E_INVALID_CAST: String = "E2020"
// Struct-literal syntax on a type that is not a struct.
pub const E_NOT_A_STRUCT: String = "E2018"
// A naked enum (explicit integer tags) may not carry payloads.
pub const E_NAKED_ENUM_PAYLOAD: String = "E2047"
// An integer / float literal outside its (resolved) type's range.
pub const E_LITERAL_RANGE: String = "E2029"
// A literal shift count at or beyond the shifted operand's bit width.
pub const E_SHIFT_RANGE: String = "E2121"
// An integer cast to a reference. A reference fabricated from an address the compiler never tracked
// defeats the escape analysis behind copy-on-write parameters, so the inbound direction is closed;
// `&T as usize` stays open under W2004.
pub const E_INT_TO_REF: String = "E2122"
// An empty array literal with nothing to fix its element type.
pub const E_EMPTY_ARRAY: String = "E2026"
// `&<temporary>` - the reference would outlive the value.
pub const E_ADDR_OF_TEMPORARY: String = "E2040"
// A generic type named in expression position without its arguments.
pub const E_BARE_GENERIC: String = "E2104"
// A parameter's default value does not have the parameter's type.
pub const E_DEFAULT_PARAM_TYPE: String = "E2070"
// An operator applied to operands with no `op_*` implementation.
pub const E_OP_NO_IMPL: String = "E2017"
// `&fn(...)` - function types are already pointer-sized.
pub const E_REF_TO_FN: String = "E2006"
// Iterator protocol (spec 4.6): the iterable has no `iter` (E2021), the state has no `next`
// (E2023), or `next` does not return `Option(T)` (E2025).
pub const E_NO_ITER: String = "E2021"
pub const E_NO_NEXT: String = "E2023"
pub const E_NEXT_RETURN: String = "E2025"
// Both `op_index` and `op_index_ref` declared for one (Self, Idx) pair.
pub const E_INDEX_AMBIGUOUS: String = "E2077"
// `?` inside a `defer` body - there is no return path to take.
pub const E_TRY_IN_DEFER: String = "E2091"

// A `let`/`const` re-declared in the SAME scope. Cross-scope shadowing stays silent; this only
// fires when the earlier binding becomes unreachable in the same block (reference parity: a warning
// locally, an error at module scope, where it is E2005).
pub const W_SAME_SCOPE_SHADOW: String = "W1002"

// A project function no root reaches through the recorded resolution edges (resolved targets,
// operator picks, specializations). Roots: `main`, and every `pub fn` when the project is a
// library. `_`-prefixed names opt out, like W1001.
pub const W_UNUSED_FUNCTION: String = "W1003"

// An `import` no recorded resolution edge lands in: nothing from the imported module (or anything
// it re-exports through `pub import`) is used by the importing file. `pub import` never warns - the
// re-export is its purpose.
pub const W_UNUSED_IMPORT: String = "W1004"

pub const W_DEPRECATED: String = "W2001"
pub const W_DEPRECATED_FN: String = "W2002"
pub const W_UNKNOWN_DIRECTIVE: String = "W2003"

// A reference cast to an integer. Reading an address is legitimate (null checks, containment
// checks, pointer identity), so the warning is suppressed per site with `#allow(W2004)`.
pub const W_REF_TO_INT: String = "W2004"
