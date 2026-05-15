//! TEST: type_alias_basic
//! EXIT: 45

// `type X = <type-expr>` (RHS not a struct/enum builder) introduces a
// transparent alias: X and the RHS are interchangeable.

pub type VarId = u32
pub type NodeId = usize
pub type Pair = (i32, i32)
pub type RefU32 = &u32

type Buf = [u8; 4]

pub fn id_of(v: VarId) u32 {
    return v
}

pub fn main() i32 {
    let v: VarId = 7u32
    let n: NodeId = 35usize
    let r: u32 = id_of(v)           // VarId flows into u32 transparently
    let p: Pair = (1i32, 2i32)
    let buf: Buf = [0u8, 0u8, 0u8, 0u8]
    return (r as i32) + (n as i32) + p.0 + p.1 + (buf[0] as i32)
}
