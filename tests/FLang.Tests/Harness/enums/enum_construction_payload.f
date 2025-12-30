//! TEST: enum_construction_payload
//! EXIT: 55

enum Command {
    Quit
    Move(i32, i32)
    Write(i32)
}

pub fn main() i32 {
    // Construct with fully qualified name
    let c1: Command = Command.Move(10, 20)
    let c2: Command = Command.Write(25)
    let c3: Command = Command.Quit
    
    let sum = process(c1) + process(c2) + process(c3)
    return sum
}

fn process(cmd: Command) i32 {
    return cmd match {
        Quit => 0,
        Move(x, y) => x + y,
        Write(val) => val
    }
}

