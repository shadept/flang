// Canonical error and warning codes the typer emits.
//
// The reporter formats every `Diagnostic` with one of these as the
// `code` field. Keeping them centralised here makes it cheap to audit
// the catalogue and update `docs/error-codes.md` in lock-step.

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
// A pattern form the front end cannot yet represent. Reported rather than
// ignored: an unrepresented pattern would otherwise be indistinguishable
// from a wildcard and silently match everything.
pub const E_UNSUPPORTED_PATTERN: String = "E2115"
// A generic struct constructed by name without its type arguments
// (`Pair { ... }` where `Pair` is `struct(T)`). Same code the reference
// checker uses for this shape.
pub const E_GENERIC_NEEDS_ARGS: String = "E2019"
// Indexing. `bool` is never a valid index; a type with neither
// `op_index_ref` nor `op_index` cannot be indexed at all.
// Branch joins: if/else branches, and match arms, that cannot agree on
// one type.
pub const E_BRANCH_MISMATCH: String = "E2074"
pub const E_ARM_MISMATCH: String = "E2075"
pub const E_BAD_INDEX_TYPE: String = "E2027"
pub const E_NOT_INDEXABLE: String = "E2028"
// RFC-009 postfix `?`: outside a function there is no return slot to
// early-return through; without a viable `op_try` the operand type does
// not participate in `?` at all. Same codes as the reference.
pub const E_TRY_OUTSIDE_FN: String = "E2090"
pub const E_NO_OP_TRY: String = "E2092"

pub const W_DEPRECATED: String = "W2001"
pub const W_DEPRECATED_FN: String = "W2002"
pub const W_UNKNOWN_DIRECTIVE: String = "W2003"
