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

pub const W_DEPRECATED: String = "W2001"
pub const W_DEPRECATED_FN: String = "W2002"
pub const W_UNKNOWN_DIRECTIVE: String = "W2003"
