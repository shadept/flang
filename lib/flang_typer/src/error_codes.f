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
// pattern would otherwise be indistinguishable from a wildcard and silently match everything. A
// generic struct constructed by name without its type arguments (`Pair { ... }` where `Pair` is
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

// RFC-037: a capturing closure, or a value of a FLang function type, where a `#foreign fn` is
// expected; and a `#foreign struct` field holding a `{ code, env }` pair. E2112 and E2113 are
// retired: captures are by reference (RFC-033), so a capture may be assigned, and a nested closure
// takes its capture from the enclosing environment.
pub const E_CLOSURE_TO_FN: String = "E2111"
pub const E_FOREIGN_PAIR_FIELD: String = "E2157"

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

// A struct literal that leaves a field out. The slot's zero bytes are a value the author never
// wrote, and a field added later would take them at every existing site without a word.
pub const E_MISSING_FIELD: String = "E2050"
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
// Iterator protocol (spec 4.6): the iterable has no `iter` (E2021), the state has no `next`
// (E2023), or `next` does not return `Option(T)` (E2025).
pub const E_NO_ITER: String = "E2021"
pub const E_NO_NEXT: String = "E2023"
pub const E_NEXT_RETURN: String = "E2025"
// Both `op_index` and `op_index_ref` declared for one (Self, Idx) pair.
pub const E_INDEX_AMBIGUOUS: String = "E2077"
// `?` inside a `defer` body - there is no return path to take.
pub const E_TRY_IN_DEFER: String = "E2091"

// Ownership (RFC-028). A type is non-copyable when a field is declared `owned`, or when a field's
// own type is non-copyable; copying such a value would duplicate the release responsibility with no
// way to say which copy holds it.
//
// A binding of a non-copyable type is live or moved: `move` takes it to moved, an assignment takes
// it back to live.
pub const E_USE_AFTER_MOVE: String = "E2123"
// A site that would copy a non-copyable value: a rebinding, a by-value argument, a struct-literal
// field, an element store, or a by-value return of a local.
pub const E_COPY_NEEDS_MOVE: String = "E2124"
// `move` over something with no storage to take. An rvalue leaves nothing behind, so there is
// nothing to mark moved.
pub const E_MOVE_NOT_LVALUE: String = "E2125"
// An assignment over a binding that still holds a value: the old one is overwritten and whatever it
// held is leaked.
pub const E_ASSIGN_OVER_LIVE: String = "E2126"
// `move base.field` outside the module declaring `base`'s type. Moving a field takes the same
// rights as writing one (E2114).
pub const E_PARTIAL_MOVE: String = "E2127"
// A `move self` parameter reached through a `&T` receiver or an `op_deref` hop. The value behind
// the reference stays with its owner, so nothing is left to hand over (RFC-033).
pub const E_CONSUMING_RECEIVER: String = "E2128"
// `move` written in argument or receiver position. The parameter declares whether a call takes
// ownership; the call site carries no marker (RFC-033).
pub const E_MOVE_IN_ARGUMENT: String = "E2129"
// `x: move &T`: a reference is copyable, and owning it says nothing about the value it refers to.
// Also a `move` past the 64th parameter, which a function type's mode mask cannot carry.
pub const E_MOVE_REF_PARAM: String = "E2130"
// A use that needs ownership of a value the function does not own: a non-copyable `x: T` parameter
// written, shared, returned, bound or moved, or a field moved out of a value reached through `&T`.
pub const E_NOT_OWNED: String = "E2131"
// A non-copyable temporary that lands where nothing takes ownership - a `T` parameter, a read-only
// receiver, an operator operand, a field read, a discarded result - is never released.
pub const E_RVALUE_NO_OWNER: String = "E2132"
// One call both moves a place and lends or shares a place overlapping it with owned state.
pub const E_MOVE_AND_LEND: String = "E2133"
// A call binds a type parameter to a type its `where` bound rejects: a contract requirement that
// does not resolve, a callable of the wrong shape, a non-copyable type under `copyable` (RFC-035).
// Also a bounded type applied to arguments its parameters' bounds reject (RFC-036).
pub const E_BOUND_UNSATISFIED: String = "E2134"
// A `where` entry that is not a contract on one of the function's own type parameters, or a
// contract applied to the wrong number of arguments, or a `+` operand that is not a contract.
pub const E_BAD_BOUND: String = "E2135"
// A contract where a value of it is needed: a parameter, field, payload, type argument or local
// (RFC-035; the type-position sugar is not implemented).
pub const E_CONTRACT_VALUE: String = "E2138"
// `Self` outside a named struct, enum or contract body.
pub const E_SELF_OUTSIDE: String = "E2139"
// A type, type parameter or generic parameter declared with the reserved name `Self`.
pub const E_SELF_DECLARED: String = "E2140"
// A contract requirement whose parameters and return type never mention `Self`.
pub const E_REQUIREMENT_NO_SELF: String = "E2141"
// A projection `X.Item` that no contract bounding `X` declares, or on something other than a type
// parameter (RFC-036).
pub const E_UNKNOWN_ASSOC: String = "E2142"
// `Name(Item = T)` or `Name(Item: B)` naming an associated type the contract does not declare, the
// same one twice, or written outside a bound.
pub const E_BAD_ASSOC_ARG: String = "E2143"
// A type parameter's bound naming a later parameter of the same list.
pub const E_LATER_PARAM: String = "E2144"
// `where` on a type declaration: a type's bounds sit on its parameters. Raised by the parser.
pub const E_WHERE_ON_TYPE: String = "E2145"
// A generic body calls a value whose type is a type parameter with no callable bound.
pub const E_UNBOUNDED_CALL: String = "E2146"

// Runtime context (RFC-038). A context field's type is not copyable: the language copies a context.
pub const E_CONTEXT_NOT_COPYABLE: String = "E2147"
// A context field's default is not a constant initializer: the root context is a static.
pub const E_CONTEXT_DEFAULT: String = "E2148"
// The current context taken as a place: `&context`, `&context.f`, or an assignment into it.
pub const E_CONTEXT_PLACE: String = "E2149"
// `context.f` or a rebind's `f = v` naming no context field visible from the module.
pub const E_CONTEXT_UNKNOWN: String = "E2150"
// One rebind naming the same field twice.
pub const E_CONTEXT_TWICE: String = "E2151"
// Two context fields of one name visible from the module.
pub const E_CONTEXT_AMBIGUOUS: String = "E2152"
// A rebind's base context not first or not alone, or a `Context` built by a struct literal.
pub const E_CONTEXT_BASE: String = "E2153"
// A lambda without `=>` where the expected callable takes more than one parameter, or nothing says
// how many (RFC-039).
pub const E_ARROWLESS_ARITY: String = "E2154"
// A type or type parameter whose name starts lowercase, or a function whose name starts uppercase
// (RFC-039).
pub const E_NAME_CASE: String = "E2155"
// A trailing lambda on a call with no parameter it can fill: a callable one with only defaulted
// parameters after it (RFC-039).
pub const E_NO_TRAILING_SLOT: String = "E2156"

// A `&move T` parameter outside `core`: the one mode that takes a value out of storage its caller
// keeps is the core library's alone (RFC-033).
pub const E_SLOT_OUTSIDE_CORE: String = "E2136"

// A `&move T` slot left empty: the value was taken out and none put back.
pub const E_SLOT_NOT_REFILLED: String = "E2137"

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

// `move` at a site that does not consume. It does nothing, so a `move` that outlives its type
// becoming copyable does not break the build.
pub const W_MOVE_NO_CONSUME: String = "W2005"

// `return move x` of a binding. A returned binding can only move, so the marker says nothing.
pub const I_REDUNDANT_MOVE: String = "I2001"
