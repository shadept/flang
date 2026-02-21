// Reusable #enum_utils source generator.
//
// #enum_utils(E) generates:
//   - to_string(self: E) String — match-based variant name
//   - from_string(s: String) E? — if-chain lookup by name
//
// Works with payload-less enums only.

#define(enum_utils, E: Type) {
    pub fn to_string(self: #(E.name)) String {
        return self match {
            #for v in type_of(E.name).fields {
                #(E.name).#(v.name) => #("\"" + v.name + "\""),
            }
        }
    }

    pub fn from_string(s: String) #(E.name)? {
        #for v in type_of(E.name).fields {
            if s == #("\"" + v.name + "\"") { return #(E.name).#(v.name) }
        }
        return null
    }
}
