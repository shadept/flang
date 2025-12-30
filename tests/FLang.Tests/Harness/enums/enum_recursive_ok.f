//! TEST: enum_recursive_ok
//! EXIT: 3

// OK: Recursive enum using reference (linked list)
enum List(T) {
    Cons(T, &List(T))
    Nil
}

pub fn main() i32 {
    // Create a simple linked list: 1 -> 2 -> 3 -> Nil
    let nil: List(i32) = List.Nil
    let list3: List(i32) = List.Cons(3, nil)
    let list2: List(i32) = List.Cons(2, &list3)
    let list1: List(i32) = List.Cons(1, &list2)
    
    // For now, just return a value to prove it compiles
    return count_list(&list1)
}

fn count_list(lst: &List($T)) i32 {
    // Match on &EnumType automatically dereferences
    return lst match {
        Nil => 0,
        Cons(_, tail) => 1 + count_list(tail)
    }
}

