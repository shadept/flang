# FLang v2 Formal Grammar

This document defines the formal grammar for FLang v2 using Extended Backus-Naur Form (EBNF) notation. This is the authoritative syntactic specification for self-hosting.

## Notation

- `::=` defines a production rule
- `|` denotes alternatives
- `?` optional (0 or 1)
- `*` repetition (0 or more)
- `+` repetition (1 or more)
- `()` grouping
- `""` literal tokens
- `,?` shorthand for optional comma (comma-or-newline separation)

## Module Structure

```ebnf
program         ::= module

module          ::= import* declaration* EOF

import          ::= "import" path_segment ("." path_segment)*

path_segment    ::= IDENTIFIER | "test"

declaration     ::=
    struct_decl
  | enum_decl
  | function_decl
  | foreign_decl
  | test_decl
  | const_decl

const_decl      ::= "pub"? "const" IDENTIFIER (":" type)? ("=" expression)?
```

## Struct Declaration

```ebnf
struct_decl     ::= "pub"? "struct" IDENTIFIER generic_params? "{" struct_fields "}"

generic_params  ::= "(" IDENTIFIER ("," IDENTIFIER)* ")"

struct_fields   ::= (struct_field ","?)*

struct_field    ::= IDENTIFIER ":" type
```

## Enum Declaration

```ebnf
enum_decl       ::= "pub"? "enum" IDENTIFIER generic_params? "{" enum_variants "}"

enum_variants   ::= (enum_variant ","?)*

enum_variant    ::= IDENTIFIER variant_payload? explicit_tag?

variant_payload ::= "(" type ("," type)* ")"

explicit_tag    ::= "=" "-"? INTEGER
```

When any variant has an `explicit_tag`, the enum is a naked enum (C-style integers). Naked enums cannot have payloads.

## Function Declaration

```ebnf
function_decl   ::= "pub"? "fn" IDENTIFIER "(" param_list? ")" return_type? block

foreign_decl    ::= "#" "foreign" "fn" IDENTIFIER "(" param_list? ")" return_type?

param_list      ::= param ("," param)*

param           ::= IDENTIFIER ":" type

return_type     ::= type
```

Return type is written directly after `)` with no arrow or colon.

## Test Declaration

```ebnf
test_decl       ::= "test" STRING block
```

## Statements

```ebnf
block           ::= "{" statement* trailing_expr? "}"

trailing_expr   ::= expression

statement       ::=
    var_decl
  | return_stmt
  | break_stmt
  | continue_stmt
  | defer_stmt
  | for_loop
  | block
  | expression_stmt

var_decl        ::= ("let" | "const") IDENTIFIER (":" type)? ("=" expression)?

return_stmt     ::= "return" expression?

break_stmt      ::= "break"

continue_stmt   ::= "continue"

defer_stmt      ::= "defer" expression

for_loop        ::= "for" "(" IDENTIFIER "in" expression ")" expression

expression_stmt ::= expression
```

A block's last expression (without an intervening statement keyword) becomes the block's value (trailing expression).

## Expressions

### Precedence (lowest to highest)

```ebnf
expression      ::= assignment | binary_expr

assignment      ::= lvalue "=" expression

lvalue          ::= IDENTIFIER | member_access | index_expr | deref_expr

binary_expr     ::= unary_expr (binary_op unary_expr)*
```

Binary operators, from lowest to highest precedence:

| Precedence | Operators | Associativity |
|---|---|---|
| 1 | `??` | right |
| 2 | `or` | left |
| 3 | `and` | left |
| 4 | `==` `!=` | left |
| 5 | `<` `>` `<=` `>=` | left |
| 6 | `..` | left |
| 7 | `+` `-` | left |
| 8 | `*` `/` `%` | left |

```ebnf
binary_op       ::=
    "??" | "or" | "and"
  | "==" | "!=" | "<" | ">" | "<=" | ">="
  | ".." | "+" | "-" | "*" | "/" | "%"
```

### Unary and Primary

```ebnf
unary_expr      ::= ("&" | "-" | "!") primary_expr postfix* cast*
                   | primary_expr postfix* cast* match_suffix?

primary_expr    ::=
    INTEGER
  | STRING
  | "true" | "false" | "null"
  | IDENTIFIER (call_args | struct_body)?
  | "." struct_body
  | tuple_or_grouped
  | if_expr
  | block
  | array_literal
```

### Postfix Operators

```ebnf
postfix         ::=
    "." "*"                                         -- dereference
  | "." IDENTIFIER call_args?                       -- field access or UFCS method call
  | "." INTEGER                                     -- tuple field (t.0, t.1)
  | "?." IDENTIFIER                                 -- null-propagation
  | "[" expression "]"                              -- index

cast            ::= "as" type

match_suffix    ::= "match" "{" match_arm* "}"
```

### Match

```ebnf
match_arm       ::= pattern "=>" expression ","?

pattern         ::=
    "_"                                             -- wildcard
  | "else"                                          -- default
  | IDENTIFIER "." IDENTIFIER variant_patterns?     -- qualified variant
  | IDENTIFIER variant_patterns?                    -- short variant or binding
  | IDENTIFIER                                      -- variable binding (in sub-patterns)

variant_patterns ::= "(" pattern ("," pattern)* ")"
```

In sub-patterns (inside variant payload), a bare identifier is a variable binding. At the top level of a match arm, a bare identifier is treated as an enum variant (resolved by the type checker).

### Call and Construction

```ebnf
call_args       ::= "(" (expression ("," expression)*)? ")"

struct_body     ::= "{" (field_init ","?)* "}"

field_init      ::= IDENTIFIER "=" expression
```

### Tuple and Grouping

```ebnf
tuple_or_grouped ::=
    "(" ")"                                         -- unit value
  | "(" expression ")"                              -- grouped expression
  | "(" expression "," ")"                          -- single-element tuple
  | "(" expression ("," expression)+ ","? ")"       -- multi-element tuple
```

### If Expression

```ebnf
if_expr         ::= "if" "(" expression ")" expression ("else" expression)?
```

Parentheses around the condition are required. `else if` chains are nested `if_expr` in the else branch.

### Array Literal

```ebnf
array_literal   ::=
    "[" "]"                                         -- empty array
  | "[" expression ";" INTEGER "]"                  -- repeat: [value; count]
  | "[" expression ("," expression)* ","? "]"       -- element list
```

## Types

```ebnf
type            ::= prefix_type "?"*

prefix_type     ::= "&" prefix_type | base_type "[]"*

base_type       ::=
    IDENTIFIER generic_args?                        -- named or generic type
  | "$" IDENTIFIER                                  -- generic parameter binding
  | "[" type ";" INTEGER "]"                        -- fixed-size array
  | "fn" "(" fn_type_params? ")" type               -- function type
  | tuple_type

generic_args    ::= "(" type ("," type)* ")"

fn_type_params  ::= fn_type_param ("," fn_type_param)*

fn_type_param   ::= (IDENTIFIER ":")? type

tuple_type      ::=
    "(" ")"                                         -- unit type
  | "(" type ")"                                    -- grouped (not a tuple)
  | "(" type "," ")"                                -- single-element tuple
  | "(" type ("," type)+ ","? ")"                   -- multi-element tuple
```

### Type Precedence

Postfix operators bind as: `&` > `[]` > `?`

| Written | Parsed as |
|---|---|
| `&u8?` | `(&u8)?` |
| `&u8[]` | `&(u8[])` |
| `&u8[]?` | `(&(u8[]))?` |

## Lexical Grammar

```ebnf
IDENTIFIER      ::= LETTER (LETTER | DIGIT | "_")*
LETTER          ::= "A".."Z" | "a".."z"
DIGIT           ::= "0".."9"
INTEGER         ::= DIGIT+
STRING          ::= '"' (CHAR | ESCAPE)* '"'
ESCAPE          ::= "\" ("n" | "t" | "r" | "\" | '"' | "0")

COMMENT         ::= "//" CHAR* NEWLINE
WHITESPACE      ::= (" " | "\t" | "\n" | "\r")+
```

Single-line comments only. No block comments.

## Tokens

### Keywords

```
pub  fn  struct  enum  let  const  if  else  for  in
break  continue  return  defer  match  import  as  test
and  or  true  false  null
```

### Symbols

```
+  -  *  /  %  .  ..  &  ?  ??  ?.  =>  !
==  !=  <  >  <=  >=
(  )  {  }  [  ]  :  =  ;  #  ,  $  _
```

## Separator Rules

- No semicolons as statement terminators
- Struct fields: comma or newline
- Enum variants: comma or newline
- Match arms: comma or newline
- Function parameters: comma required
- Call arguments: comma required
- Type arguments: comma required
- Array elements: comma required (trailing comma optional)
- Tuple elements: comma required (trailing comma optional)
