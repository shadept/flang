// Source generator that produces forwarding overloads for any type T that has
// an `as_view() String` method.  Invoke as:  #string_reader(MyType)

import std.string

#define(string_reader, T: Type) {
    pub fn find(s: #(T.name), needle: String) usize? { return find(s.as_view(), needle) }
    pub fn rfind(s: #(T.name), needle: String) usize? { return rfind(s.as_view(), needle) }
    pub fn contains(s: #(T.name), needle: String) bool { return contains(s.as_view(), needle) }
    pub fn starts_with(s: #(T.name), prefix: String) bool { return starts_with(s.as_view(), prefix) }
    pub fn ends_with(s: #(T.name), suffix: String) bool { return ends_with(s.as_view(), suffix) }
    pub fn trim(s: #(T.name)) String { return trim(s.as_view()) }
    pub fn trim_start(s: #(T.name)) String { return trim_start(s.as_view()) }
    pub fn trim_end(s: #(T.name)) String { return trim_end(s.as_view()) }
}
