// Reusable #interface and #implement source generators.
//
// #interface(Name, Spec) — generates a vtable struct, wrapper struct, and
//   forwarding dispatch methods for a trait-like interface.
//
// #implement(Impl, Iface) — generates shim functions, a static vtable
//   constant, and a conversion function (lower-cased interface name) on the
//   implementing type.

#define(interface, Name: Ident, Spec: Type) {
    type #(Name)Vtable = struct {
        #for field in Spec.fields {
            #(field.name): fn(ctx: &u8,
                #for param in field.type_info.params {
                    #(param.name): #(param.type_info.name),
                }) #(field.type_info.return_type.name)
        }
    }

    type #(Name) = struct {
        _ctx: &u8
        _vtable: &#(Name)Vtable
    }

    #for field in Spec.fields {
        pub fn #(field.name)(self: &#(Name),
            #for param in field.type_info.params {
                #(param.name): #(param.type_info.name),
            }) #(field.type_info.return_type.name) {
            return self._vtable.#(field.name)(self._ctx,
                #for param in field.type_info.params {
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
            } ) #(field.type_info.return_type.name) {
            let self = ctx as &#(Impl.name)
            return self.#(field.name)(
                #for param in field.type_info.params[1..] {
                    #(param.name),
                })
        }
    }

    const __#(Impl.name)_#(Iface.name)_vtable = #(Iface.name)Vtable {
        #for field in type_of(Iface.name + "Vtable").fields {
            #(field.name) = __#(Impl.name)_#(Iface.name)_#(field.name),
        }
    }

    pub fn #(snake_case(Iface.name))(self: &#(Impl.name)) #(Iface.name) {
        return #(Iface.name) {
            _ctx = self as &u8,
            _vtable = &__#(Impl.name)_#(Iface.name)_vtable,
        }
    }
}
