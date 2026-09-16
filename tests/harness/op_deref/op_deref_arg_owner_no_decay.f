//! TEST: op_deref_arg_owner_no_decay
//! COMPILE-ERROR: E2011
//! EXIT: 1

type Payload = struct {
    owned handle: i32
}

type Keeper = struct {
    payload: Payload
}

fn op_deref(self: &Keeper) &Payload {
    return &self.payload
}

fn consume(p: Payload) i32 {
    return 1
}

// The value leg decays an owner to a copyable view. Peeling to a non-copyable value would hand the
// same resource to two owners, so it is refused.
pub fn main() i32 {
    const k = Keeper { payload = Payload { handle = 7 } }
    return consume(k)
}
