//! TEST: define_interface
//! EXIT: 0

// Full interface + implement pattern using source generators.

#define(interface, Name: Ident, Spec: Type) {
    type #(Name)Vtable = struct {
        #for field in Spec.fields {
            #(field.name): fn(ctx: &u8, #for param in field.type_info.params {
                #(param.name): #(param.type_info.name),
            }) #(field.type_info.return_type.name)
        }
    }

    type #(Name) = struct {
        _ctx: &u8
        _vtable: &#(Name)Vtable
    }

    #for field in Spec.fields {
        fn #(field.name)(self: &#(Name), #for param in field.type_info.params {
            #(param.name): #(param.type_info.name),
        }) #(field.type_info.return_type.name) {
            return self._vtable.#(field.name)(self._ctx, #for param in field.type_info.params {
                #(param.name),
            })
        }
    }
}

#define(implement, Impl: Type, Iface: Type) {
    #for field in type_of(Iface.name + "Vtable").fields {
        fn __#(Impl.name)_#(Iface.name)_#(field.name)(
            #for param in field.type_info.params {
                #(param.name): #(param.type_info.name),
            }
        ) #(field.type_info.return_type.name) {
            let self = ctx as &#(Impl.name)
            return self.#(field.name)(#for param in field.type_info.params[1..] {
                #(param.name),
            })
        }
    }

    const __#(Impl.name)_#(Iface.name)_vtable = #(Iface.name)Vtable {
        #for field in type_of(Iface.name + "Vtable").fields {
            #(field.name) = __#(Impl.name)_#(Iface.name)_#(field.name),
        }
    }

    fn #(lower(Iface.name))(self: &#(Impl.name)) #(Iface.name) {
        return #(Iface.name) {
            _ctx = self as &u8,
            _vtable = &__#(Impl.name)_#(Iface.name)_vtable,
        }
    }
}

// === Use the generators ===

#interface(Writer, struct {
    write: fn(data: u8[]) usize
    flush: fn() bool
})

type StringBuilder = struct {
    total: usize
}

fn write(self: &StringBuilder, data: u8[]) usize {
    self.total = self.total + data.len
    return data.len
}

fn flush(self: &StringBuilder) bool {
    return true
}

#implement(StringBuilder, Writer)

pub fn main() i32 {
    let sb = StringBuilder { total = 0 }
    let w = sb.writer()

    let n = w.write("hello")
    if n != 5 { return 1 }
    if sb.total != 5 { return 2 }

    let ok = w.flush()
    if !ok { return 3 }

    return 0
}
