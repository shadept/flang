// Open-document store. One entry per open buffer, keyed by URI, carrying the full text (sync is
// TextDocumentSyncKind.Full), its version, and a LineIndex rebuilt on every change. Open buffers
// win over disk: whatever is in here is the text the rest of the server analyses and answers about.

import std.allocator
import std.dict
import std.option
import std.string
import std.test
import flang_lsp.line_index
import flang_lsp.uri

pub type Document = struct {
    text: OwnedString
    // The filesystem spelling of the entry's URI (uri.f's convention), empty for non-file URIs. The
    // URI is the protocol's name for the buffer and is echoed back verbatim; the path is what
    // analysis, manifest discovery and watcher events compare against, converted once here rather
    // than on every use.
    path: OwnedString
    version: i64
    index: LineIndex
}

pub fn deinit(self: &Document) {
    self.text.deinit()
    self.path.deinit()
    self.index.deinit()
}

pub type DocumentStore = struct {
    docs: Dict(OwnedString, Document)
}

pub fn document_store(allocator: &Allocator? = null) DocumentStore {
    return .{ docs = dict(allocator) }
}

pub fn deinit(self: &DocumentStore) {
    self.docs.deinit()
}

pub fn len(self: &DocumentStore) usize {
    return self.docs.len()
}

// didOpen: (re)create the entry. An already-open URI is replaced.
pub fn open(self: &DocumentStore, uri: String, version: i64, text: String) {
    self.close(uri)
    const p = uri_to_path(uri)
    const doc = Document {
        text = from_view(text),
        path = p ?? from_view(""),
        version = version,
        index = line_index(text),
    }
    self.docs.set(uri, doc)
}

// didChange, full sync: replace the text wholesale. A change for a URI that is not open is dropped
// - there is no buffer for it to apply to.
pub fn change(self: &DocumentStore, uri: String, version: i64, text: String) {
    const existing = self.docs.get_ref(uri)
    if existing.is_none() {
        return
    }
    let doc = existing.unwrap()
    doc.text.deinit()
    doc.index.deinit()
    doc.text = from_view(text)
    doc.index = line_index(doc.text.as_view())
    doc.version = version
}

// didClose: drop the entry. Closing an unknown URI is a no-op.
pub fn close(self: &DocumentStore, uri: String) {
    const removed = self.docs.remove(uri)
    if removed.is_some() {
        let doc = removed.unwrap()
        doc.deinit()
    }
}

pub fn get(self: &DocumentStore, uri: String) &Document? {
    return self.docs.get_ref(uri)
}

// Tests

test "open, change, close lifecycle" {
    let store = document_store()
    defer store.deinit()

    store.open("file:///a.f", 1, "let x = 1\n")
    assert_eq(store.len(), 1, "one open document")
    assert_eq(store.get("file:///a.f").unwrap().text.as_view(), "let x = 1\n", "text stored")

    store.change("file:///a.f", 2, "let x = 2\n")
    const doc = store.get("file:///a.f").unwrap()
    assert_eq(doc.text.as_view(), "let x = 2\n", "full sync replaces the buffer")
    assert_eq(doc.version, 2, "version follows")

    store.close("file:///a.f")
    assert_true(store.get("file:///a.f").is_none(), "closed document is gone")
    assert_eq(store.len(), 0, "store empty again")
}

test "change for an unopened uri is dropped" {
    let store = document_store()
    defer store.deinit()
    store.change("file:///ghost.f", 1, "boo")
    assert_eq(store.len(), 0, "nothing materializes")
}

test "reopening replaces the previous buffer" {
    let store = document_store()
    defer store.deinit()
    store.open("file:///a.f", 1, "old")
    store.open("file:///a.f", 5, "new")
    assert_eq(store.len(), 1, "still one entry")
    const doc = store.get("file:///a.f").unwrap()
    assert_eq(doc.text.as_view(), "new", "latest open wins")
    assert_eq(doc.version, 5, "with its version")
}
