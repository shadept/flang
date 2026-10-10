// Releasing a value whose type is still open.
//
// There is no blanket `deinit`: a type that owns memory declares its own, and a generic container
// reaches its elements through `release` rather than through a call every type would answer. A
// blanket is what made a container free its buffer and leak everything the elements held, picked
// per binary and reported nowhere (docs/known-issues.md).

pub fn release(value: move $T) {
    #if !type_info(T).copyable {
        value.deinit()
    }
}

// A zero-size field that makes the type holding it non-copyable: for a value that carries a release
// obligation but owns no storage to mark `owned`, such as a drain.
pub type NoCopy = struct {
    owned __marker: ()
}

pub fn no_copy() NoCopy {
    return .{ __marker = () }
}

// Nothing to release: the holder's own `deinit` meets the obligation.
pub fn deinit(self: move NoCopy) {}
