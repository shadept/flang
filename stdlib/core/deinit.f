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
