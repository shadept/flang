# FLang v2 EBNF Grammar

This document defines the formal grammar for FLang v2 using Extended Backus-Naur Form (EBNF) notation.

## Notation Conventions

- `::=` defines a production rule
- `|` denotes alternatives (OR)
- `?` postfix denotes optional (0 or 1 occurrence)
- `*` postfix denotes repetition (0 or more occurrences)
- `()` denotes grouping
- `""` denotes literal tokens

## Complete Grammar

```
program ::= module

module ::= import_declaration* declaration* EOF

import_declaration ::= "import" identifier ("." identifier)*

declaration ::= 
    struct_declaration |
    function_declaration |
    foreign_function_declaration

struct_declaration ::= "pub"? "struct" identifier generic_parameters? "{" struct_field (","? struct_field)* "}"

generic_parameters ::= "(" identifier ("," identifier)* ")"

struct_field ::= identifier ":" type

function_declaration ::= "pub"? "fn" identifier "(" parameter_list? ")" (":" type)? block_expression

foreign_function_declaration ::= "#" "foreign" "fn" identifier "(" parameter_list? ")" (":" type)?

parameter_list ::= parameter ("," parameter)*
parameter ::= identifier ":" type

type ::= reference_type postfix_operator*

reference_type ::= "&"? primary_type

primary_type ::= 
    named_type generic_arguments? |
    array_type

named_type ::= "$"? identifier

generic_arguments ::= "[" type ("," type)* "]"

array_type ::= "[" type ";" integer_literal "]"

postfix_operator ::= 
    nullable_operator |
    slice_operator

nullable_operator ::= "?"
slice_operator ::= "[" "]"

expression ::= binary_expression

; Casts are parsed after postfix operators
cast_expression ::= primary_expression ("as" type)*

binary_expression ::= unary_expression (binary_operator unary_expression)*

unary_expression ::= 
    address_of_expression |
    primary_expression

address_of_expression ::= "&" primary_expression

primary_expression ::= 
    literal |
    identifier_expression |
    parenthesized_expression |
    if_expression |
    block_expression |
    array_literal |
    struct_construction |
    call_expression

cast_expression ::= primary_expression ("as" type)*

literal ::= integer_literal | string_literal | "true" | "false"

identifier_expression ::= identifier postfix_expression?

postfix_expression ::= 
    field_access |
    dereference |
    index_expression

field_access ::= "." identifier
dereference ::= ".*"
index_expression ::= "[" expression "]"

parenthesized_expression ::= "(" expression ")"

if_expression ::= "if" "(" expression ")" expression ("else" expression)?

block_expression ::= "{" statement* expression? "}"

array_literal ::= 
    "[]" |
    "[" expression ";" integer_literal "]" |
    "[" expression ("," expression)* ","? "]"

struct_construction ::= identifier "{" struct_field_value ("," struct_field_value)* ","? "}"

struct_field_value ::= identifier ":" expression

call_expression ::= identifier "(" argument_list? ")"

argument_list ::= expression ("," expression)*

statement ::= 
    variable_declaration |
    return_statement |
    break_statement |
    continue_statement |
    defer_statement |
    for_loop |
    expression_statement

variable_declaration ::= "let" identifier (":" type)? ("=" expression)?

return_statement ::= "return" expression?

break_statement ::= "break"

continue_statement ::= "continue"

defer_statement ::= "defer" expression

for_loop ::= "for" "(" identifier "in" expression ")" expression

expression_statement ::= 
    assignment_expression |
    if_expression

assignment_expression ::= identifier "=" expression

binary_operator ::= 
    arithmetic_operator |
    comparison_operator |
    range_operator

arithmetic_operator ::= "+" | "-" | "*" | "/" | "%"

comparison_operator ::= "==" | "!=" | "<" | "<=" | ">" | ">="

range_operator ::= ".."

assignment_operator ::= "="

identifier ::= letter (letter | digit | "_")*
letter ::= "A".."Z" | "a".."z"
digit ::= "0".."9"
integer_literal ::= digit+
string_literal ::= '"' (character | escape_sequence)* '"'
escape_sequence ::= "\" ("n" | "t" | "r" | "\" | '"' | "0")

whitespace ::= (" " | "\t" | "\n" | "\r")+
comment ::= "//" character* "\n"
```

## Operator Precedence (Highest to Lowest)

1. Primary expressions (literals, identifiers, parenthesized expressions)
2. Function calls, indexing, field access, dereference (`.` `.*` `[]`)
3. Unary operators (`&`)
4. Multiplicative operators (`*` `/` `%`)
5. Additive operators (`+` `-`)
6. Range operator (`..`)
7. Comparison operators (`==` `!=` `<` `<=` `>` `>=`)
8. Assignment (`=`)

## Examples

### Function Declaration
```
pub fn add(a: i32, b: i32) i32 {
    return a + b
}
```

### Struct Declaration
```
struct Point {
    x: i32,
    y: i32
}
```

### Generic Function
```
pub fn make_list(element: $T) List[T] {
    return List { data: element }
}
```

### Array Types and Literals
```
let fixed: [i32; 5] = [1, 2, 3, 4, 5]
let repeat: [i32; 10] = [0; 10]
let slice: i32[] = &fixed
```

### Reference Types
```
let x: i32 = 42
let ptr: &i32 = &x
let value: i32 = ptr.*
let nullable_ptr: &i32? = null
```

### Control Flow
```
let result = if (condition) {
    do_something()
    42
} else {
    do_alternative()
    0
}

for (item in collection) {
    process(item)
    if (should_break) break
}
```

### Defer Statement
```
let file = open_file("test.txt")
defer close_file(file)
// file will be closed when scope exits
```

### Import Statement
```
import core.memory
import std.collections.List

pub fn main() i32 {
    let list = List[i32] {}
    return 0
}
```