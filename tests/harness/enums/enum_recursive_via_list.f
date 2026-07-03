//! TEST: enum_recursive_via_list
//! EXIT: 6

// Recursive enum through a generic container (self-hosting pattern: AST nodes)
import std.list

type Expr = enum {
    Num(i32)
    Add(List(Expr))
}

fn eval(expr: &Expr) i32 {
    return expr match {
        Num(n) => n,
        Add(children) => {
            let sum = 0
            for child in children {
                sum = sum + eval(&child)
            }
            sum
        }
    }
}

pub fn main() i32 {
    let args: List(Expr) = list(2)
    args.push(Expr.Num(1))
    args.push(Expr.Num(2))
    args.push(Expr.Num(3))
    let add_expr = Expr.Add(args)
    return eval(&add_expr)
}
