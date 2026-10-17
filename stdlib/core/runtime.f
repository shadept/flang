// Core runtime helpers shared across the standard library. __flang_unimplemented is provided by the
// C backend and aborts execution with a helpful message when a feature stub is invoked.

#foreign fn __flang_unimplemented()

// The runtime context every FLang function runs under (RFC-038). The compiler assembles its fields
// from the program's `context` declarations. A value is made by `context` and read by
// `ctx.<field>`.
pub type Context = struct {}
