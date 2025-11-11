function main:
  entry_0:
    store s = str_0
    field_ptr_0 = getelementptr %s, FLang.IR.ConstantValue
    field_load_1 = load %field_ptr_0
    return %field_load_1

