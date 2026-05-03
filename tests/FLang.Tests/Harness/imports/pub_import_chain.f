//! TEST: pub_import_chain
//! EXIT: 5

// _chain_c pub-imports _chain_b which pub-imports _chain_a.
// Importing _chain_c should make _chain_a's items visible transitively
// through the chain of `pub import` re-exports.

import _chain_c

pub fn main() i32 {
    return chain_value()
}
