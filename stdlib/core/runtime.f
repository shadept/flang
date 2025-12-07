// Core runtime helpers shared across the standard library.
// __flang_unimplemented is provided by the C backend and aborts execution
// with a helpful message when a feature stub is invoked.

#foreign fn __flang_unimplemented()
