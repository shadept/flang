// Generated from string.f

// #string_reader(OwnedString)
pub fn find(s: OwnedString, needle: String) usize? { return find(s.as_view(), needle) }
pub fn rfind(s: OwnedString, needle: String) usize? { return rfind(s.as_view(), needle) }
pub fn contains(s: OwnedString, needle: String) bool { return contains(s.as_view(), needle) }
pub fn starts_with(s: OwnedString, prefix: String) bool { return starts_with(s.as_view(), prefix) }
pub fn ends_with(s: OwnedString, suffix: String) bool { return ends_with(s.as_view(), suffix) }
pub fn trim(s: OwnedString) String { return trim(s.as_view()) }
pub fn trim_start(s: OwnedString) String { return trim_start(s.as_view()) }
pub fn trim_end(s: OwnedString) String { return trim_end(s.as_view()) }

