//! TEST: enum_construction_unit
//! EXIT: 1

enum Status {
    Idle
    Running
    Stopped
}

pub fn main() i32 {
    // Fully qualified construction
    let s1: Status = Status.Running
    
    // Short form construction (when type is known)
    let s2: Status = Idle
    
    return s1 match {
        Idle => 0,
        Running => 1,
        Stopped => 2
    }
}

