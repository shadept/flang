//! TEST: type_alias_everywhere
//! EXIT: 63

// An alias is another name for its body: it works in every position the body does, value position
// and variant paths included.

type Word = i64
type Box(T) = struct {
    type Item = T
    v: T
}
type Shelf(T) = Box(T)
type Ints = Box(i32)
type Tag(T) = enum {
    On(T)
    Off
}
type Flag = Tag(i32)
type Level = enum {
    Low
    High(i32)
}
type Grade = Level

fn unbox(b: Shelf(i32)) i32 {
    return b.v
}

pub fn main() i32 {
    type Pair = (i32, i32)
    const words: usize = size_of(Word)
    const pair: usize = size_of(Pair)
    const shelf: usize = size_of(Shelf(i16))
    const item: usize = size_of(Box(i64).Item)
    const ints: Ints = Ints { v = 4 }
    const boxed: Shelf(i32) = Shelf(i32) { v = 5 }
    const on: Flag = Flag.On(6)
    const high: Grade = Grade.High(7)
    const low: Grade = Grade.Low
    #if type_info(Word).name != "i64" {
        return 1
    }
    const a: i32 = on match {
        On(x) => x
        Off => 0
    }
    const b: i32 = high match {
        High(x) => x
        Low => 0
    }
    const c: i32 = low match {
        High(_) => 100
        Low => 0
    }
    // 8 + 8 + 2 + 8 + 4 + 5 + 6 + 7 + 0 + 15
    return (words + pair + shelf + item) as i32 + ints.v + unbox(boxed) + a + b + c + 15
}
