// Reusable #derive source generator.
//
// #derive(T, eq)          — field-by-field equality (op_eq)
// #derive(T, clone)       — field-by-field copy
// #derive(T, debug)       — format(self, sb, spec) for StringBuilder integration
// #derive(T, hash)        — recursive FNV-1a hash combining field hashes
// #derive(T, serialize)   — encode struct fields to an Encoder
// #derive(T, deserialize) — decode struct fields from a Decoder
// #derive(T, eq, clone)   — multiple traits via variadic params
//
// serialize/deserialize require: import std.encoding.codec

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
        } #else #if Trait == "serialize" {
            pub fn serialize(self: &#(T.name), enc: &Encoder) {
                enc.begin_map(#(type_of(T.name).fields.len))
                #for field in type_of(T.name).fields {
                    enc.key(#("\"" + field.name + "\""))
                    #if field.type_info.name == "bool" {
                        enc.encode_bool(self.#(field.name))
                    } #else #if field.type_info.name == "i8" {
                        encode_i8(enc, self.#(field.name))
                    } #else #if field.type_info.name == "i16" {
                        encode_i16(enc, self.#(field.name))
                    } #else #if field.type_info.name == "i32" {
                        encode_i32(enc, self.#(field.name))
                    } #else #if field.type_info.name == "i64" {
                        encode_i64(enc, self.#(field.name))
                    } #else #if field.type_info.name == "isize" {
                        encode_isize(enc, self.#(field.name))
                    } #else #if field.type_info.name == "u8" {
                        encode_u8(enc, self.#(field.name))
                    } #else #if field.type_info.name == "u16" {
                        encode_u16(enc, self.#(field.name))
                    } #else #if field.type_info.name == "u32" {
                        encode_u32(enc, self.#(field.name))
                    } #else #if field.type_info.name == "u64" {
                        encode_u64(enc, self.#(field.name))
                    } #else #if field.type_info.name == "usize" {
                        encode_usize(enc, self.#(field.name))
                    } #else #if field.type_info.name == "f32" {
                        encode_f32(enc, self.#(field.name))
                    } #else #if field.type_info.name == "f64" {
                        encode_f64(enc, self.#(field.name))
                    } #else #if field.type_info.name == "String" {
                        enc.encode_str(self.#(field.name))
                    } #else #if field.type_info.name == "OwnedString" {
                        enc.encode_str(self.#(field.name).as_view())
                    } #else {
                        self.#(field.name).serialize(enc)
                    }
                }
                enc.end_map()
            }
        } #else #if Trait == "deserialize" {
            pub fn deserialize(dec: &Decoder) #(T.name) {
                dec.begin_map()
                let result: #(T.name)
                let _key_buf = string_builder(32)
                for _i in 0..1024 {
                    _key_buf.clear()
                    if dec.next_key(&_key_buf) == false { break }
                    let _key = _key_buf.as_view()
                    #for field in type_of(T.name).fields {
                        if _key == #("\"" + field.name + "\"") {
                            #if field.type_info.name == "bool" {
                                result.#(field.name) = dec.decode_bool()
                            } #else #if field.type_info.name == "i8" {
                                result.#(field.name) = decode_i8(dec)
                            } #else #if field.type_info.name == "i16" {
                                result.#(field.name) = decode_i16(dec)
                            } #else #if field.type_info.name == "i32" {
                                result.#(field.name) = decode_i32(dec)
                            } #else #if field.type_info.name == "i64" {
                                result.#(field.name) = decode_i64(dec)
                            } #else #if field.type_info.name == "isize" {
                                result.#(field.name) = decode_isize(dec)
                            } #else #if field.type_info.name == "u8" {
                                result.#(field.name) = decode_u8(dec)
                            } #else #if field.type_info.name == "u16" {
                                result.#(field.name) = decode_u16(dec)
                            } #else #if field.type_info.name == "u32" {
                                result.#(field.name) = decode_u32(dec)
                            } #else #if field.type_info.name == "u64" {
                                result.#(field.name) = decode_u64(dec)
                            } #else #if field.type_info.name == "usize" {
                                result.#(field.name) = decode_usize(dec)
                            } #else #if field.type_info.name == "f32" {
                                result.#(field.name) = decode_f32(dec)
                            } #else #if field.type_info.name == "f64" {
                                result.#(field.name) = decode_f64(dec)
                            } #else #if field.type_info.name == "String" {
                                let _str_buf = string_builder(32)
                                dec.decode_str(_str_buf.writer())
                                result.#(field.name) = _str_buf.as_view()
                            } #else #if field.type_info.name == "OwnedString" {
                                let _str_buf = string_builder(32)
                                dec.decode_str(_str_buf.writer())
                                result.#(field.name) = _str_buf.to_string()
                            } #else {
                                result.#(field.name) = #(field.type_info.name).deserialize(dec)
                            }
                        } else
                    }
                    { dec.skip_value() }
                }
                dec.end_map()
                _key_buf.deinit()
                return result
            }
        }
    }
}
