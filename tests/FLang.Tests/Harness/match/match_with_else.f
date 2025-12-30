//! TEST: match_with_else
//! EXIT: 10

enum Command {
    Quit
    Move(i32, i32)
    Write(i32)
    Read
}

pub fn main() i32 {
    let c1: Command = Command.Quit
    let c2: Command = Command.Move(3, 7)
    let c3: Command = Command.Write(99)
    
    // Using else clause instead of matching all variants
    let r1: i32 = c1 match {
        Quit => 0,
        else => 100
    }
    
    let r2 = c2 match {
        Move(x, y) => x + y,
        else => 0
    }
    
    return r1 + r2
}

