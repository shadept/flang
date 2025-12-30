//! TEST: enum_with_payloads
//! EXIT: 42

enum Message {
    Quit
    Echo(i32)
    Move(i32, i32)
}

pub fn main() i32 {
    let m1: Message = Message.Echo(42)
    let m2: Message = Message.Move(10, 20)
    let m3: Message = Message.Quit
    
    return m1 match {
        Quit => 0,
        Echo(val) => val,
        Move(x, y) => x + y
    }
}

