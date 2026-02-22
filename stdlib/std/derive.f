// Reusable #derive source generator.
//
// #derive(T, eq)          — field-by-field equality (op_eq)
// #derive(T, clone)       — field-by-field copy
// #derive(T, debug)       — format(self, sb, spec) for StringBuilder integration
// #derive(T, hash)         — recursive FNV-1a hash combining field hashes
// #derive(T, eq, clone)   — multiple traits via variadic params

#define(derive, T: Type, ..Traits: Ident) {
    #for Trait in Traits {
        #if Trait == "eq" {
            pub fn op_eq(a: #(T.name), b: #(T.name)) bool {
                #for field in type_of(T.name).fields {
                    if a.#(field.name) != b.#(field.name) { return false }
                }
                return true
            }
        } #else #if Trait == "clone" {
            pub fn clone(self: &#(T.name)) #(T.name) {
                return #(T.name) {
                    #for field in type_of(T.name).fields {
                        #(field.name) = self.#(field.name),
                    }
                }
            }
        } #else #if Trait == "debug" {
            pub fn format(self: &#(T.name), sb: &StringBuilder, spec: String) {
                sb.append(#("\"" + T.name + " { \""))
                #for field in type_of(T.name).fields {
                    sb.append(#("\"" + field.name + " = \""))
                    sb.append(self.#(field.name))
                    sb.append(", ")
                }
                sb.append("}")
            }
        } #else #if Trait == "hash" {
            pub fn hash(self: #(T.name)) usize {
                let h: usize = 14695981039346656037
                #for field in type_of(T.name).fields {
                    h = (h ^ hash(self.#(field.name))) * 1099511628211
                }
                return h
            }
        }
    }
}
