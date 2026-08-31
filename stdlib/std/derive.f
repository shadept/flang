// Reusable #derive source generator.
//
// #derive(T, eq)          - field-by-field equality (op_eq)
// #derive(T, clone)       - field-by-field copy
// #derive(T, debug)       - format(self, w, spec) writing each field to the sink
// #derive(T, hash)        - recursive FNV-1a hash combining field hashes
// #derive(T, serialize)   - encode struct fields to an Encoder
// #derive(T, deserialize) - decode struct fields from a Decoder
// #derive(T, eq, clone)   - multiple traits via variadic params
//
// serialize/deserialize require: import std.encoding.codec

// Re-exported so a `#derive(T, debug)` expansion carries its own dependency: the generated `format`
// writes to a `Writer`, which the deriving file would otherwise have to import.
pub import std.io.writer

#define(derive, T: Type, ..Traits: Ident) {
    #for Trait in Traits {
        #if Trait.text == "eq" {
            pub fn op_eq(a: #(T.name), b: #(T.name)) bool {
                #for field in T.fields {
                    if a.#(field.name) != b.#(field.name) { return false }
                }
                return true
            }
        } #elif Trait.text == "clone" {
            pub fn clone(self: &#(T.name)) #(T.name) {
                return #(T.name) {
                    #for field in T.fields {
                        #(field.name) = self.#(field.name),
                    }
                }
            }
        } #elif Trait.text == "debug" {
            pub fn format(self: &#(T.name), w: Writer, spec: String) {
                w.write_str("#(T.name) { ")
                #for field in T.fields {
                    w.write_str("#(field.name) = ")
                    self.#(field.name).format(w, "")
                    w.write_str(", ")
                }
                w.write_str("}")
            }
        } #elif Trait.text == "hash" {
            pub fn hash(self: #(T.name)) usize {
                let h: usize = 14695981039346656037
                #for field in T.fields {
                    h = (h ^ self.#(field.name).hash()) * 1099511628211
                }
                return h
            }
        } #elif Trait.text == "serialize" {
            pub fn serialize(self: &#(T.name), enc: &Encoder) {
                enc.begin_map(#(T.fields.len))
                #for field in T.fields {
                    enc.key("#(field.name)")
                    #if field.type_info.name == "bool" {
                        enc.encode_bool(self.#(field.name))
                    } #elif field.type_info.name == "i8" {
                        encode_i8(enc, self.#(field.name))
                    } #elif field.type_info.name == "i16" {
                        encode_i16(enc, self.#(field.name))
                    } #elif field.type_info.name == "i32" {
                        encode_i32(enc, self.#(field.name))
                    } #elif field.type_info.name == "i64" {
                        encode_i64(enc, self.#(field.name))
                    } #elif field.type_info.name == "isize" {
                        encode_isize(enc, self.#(field.name))
                    } #elif field.type_info.name == "u8" {
                        encode_u8(enc, self.#(field.name))
                    } #elif field.type_info.name == "u16" {
                        encode_u16(enc, self.#(field.name))
                    } #elif field.type_info.name == "u32" {
                        encode_u32(enc, self.#(field.name))
                    } #elif field.type_info.name == "u64" {
                        encode_u64(enc, self.#(field.name))
                    } #elif field.type_info.name == "usize" {
                        encode_usize(enc, self.#(field.name))
                    } #elif field.type_info.name == "f32" {
                        encode_f32(enc, self.#(field.name))
                    } #elif field.type_info.name == "f64" {
                        encode_f64(enc, self.#(field.name))
                    } #elif field.type_info.name == "String" {
                        enc.encode_str(self.#(field.name))
                    } #elif field.type_info.name == "OwnedString" {
                        enc.encode_str(self.#(field.name).as_view())
                    } #else {
                        self.#(field.name).serialize(enc)
                    }
                }
                enc.end_map()
            }
        } #elif Trait.text == "deserialize" {
            pub fn deserialize(dec: &Decoder) #(T.name) {
                dec.begin_map()
                let result: #(T.name)
                let _key_buf = string_builder(32)
                for _i in 0..1024 {
                    _key_buf.clear()
                    if dec.next_key(&_key_buf) == false { break }
                    let _key = _key_buf.as_view()
                    #for field in T.fields {
                        if _key == "#(field.name)" {
                            #if field.type_info.name == "bool" {
                                result.#(field.name) = dec.decode_bool()
                            } #elif field.type_info.name == "i8" {
                                result.#(field.name) = decode_i8(dec)
                            } #elif field.type_info.name == "i16" {
                                result.#(field.name) = decode_i16(dec)
                            } #elif field.type_info.name == "i32" {
                                result.#(field.name) = decode_i32(dec)
                            } #elif field.type_info.name == "i64" {
                                result.#(field.name) = decode_i64(dec)
                            } #elif field.type_info.name == "isize" {
                                result.#(field.name) = decode_isize(dec)
                            } #elif field.type_info.name == "u8" {
                                result.#(field.name) = decode_u8(dec)
                            } #elif field.type_info.name == "u16" {
                                result.#(field.name) = decode_u16(dec)
                            } #elif field.type_info.name == "u32" {
                                result.#(field.name) = decode_u32(dec)
                            } #elif field.type_info.name == "u64" {
                                result.#(field.name) = decode_u64(dec)
                            } #elif field.type_info.name == "usize" {
                                result.#(field.name) = decode_usize(dec)
                            } #elif field.type_info.name == "f32" {
                                result.#(field.name) = decode_f32(dec)
                            } #elif field.type_info.name == "f64" {
                                result.#(field.name) = decode_f64(dec)
                            } #elif field.type_info.name == "String" {
                                let _str_buf = string_builder(32)
                                dec.decode_str(_str_buf.writer())
                                result.#(field.name) = _str_buf.as_view()
                            } #elif field.type_info.name == "OwnedString" {
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
