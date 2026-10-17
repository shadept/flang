// LSP 3.17 wire types: the structures the server sends, member for member in snake_case. The
// server's RpcWriter encodes with `KeyCase.Camel`, so `selection_range` goes out as
// `selectionRange` and a trailing `_` (the keyword escape in `type_`) is dropped. A `None` member
// is left out, as the spec's optional (`prop?`) members are. A spec name that a FLang type already
// takes (`Range`, `Diagnostic`) carries an `Lsp` prefix.
//
// Strings are views into whatever the handler keeps alive until the message is sent; a member the
// handler builds for the message (a URI, a joined label) is an OwnedString the value releases.

import std.collections.list
import std.derive
import std.encoding.codec
import std.option
import std.string

import flang_lsp.line_index

#derive(Position, serialize)

pub type LspRange = struct {
    start: Position
    end: Position
}

#derive(LspRange, serialize)

pub type Location = struct {
    uri: OwnedString
    range: LspRange
}

#derive(Location, serialize)

pub fn deinit(self: move Location) {
    self.uri.deinit()
}

pub type LocationLink = struct {
    origin_selection_range: LspRange
    target_uri: OwnedString
    target_range: LspRange
    target_selection_range: LspRange
}

#derive(LocationLink, serialize)

pub fn deinit(self: move LocationLink) {
    self.target_uri.deinit()
}

// ---- Diagnostics ----

pub type LspDiagnostic = struct {
    range: LspRange
    severity: i32
    code: String?
    source: String
    message: OwnedString
}

#derive(LspDiagnostic, serialize)

pub fn deinit(self: move LspDiagnostic) {
    self.message.deinit()
}

pub type PublishDiagnosticsParams = struct {
    uri: String
    diagnostics: List(LspDiagnostic)
}

#derive(PublishDiagnosticsParams, serialize)

pub fn deinit(self: move PublishDiagnosticsParams) {
    self.diagnostics.deinit()
}

// ---- Window and progress ----

pub type ShowMessageParams = struct {
    type_: i32
    message: String
}

#derive(ShowMessageParams, serialize)

pub type WorkDoneProgressCreateParams = struct {
    token: String
}

#derive(WorkDoneProgressCreateParams, serialize)

pub type WorkDoneProgress = struct {
    kind: String
    title: String?
}

#derive(WorkDoneProgress, serialize)

pub type ProgressParams = struct {
    token: String
    value: WorkDoneProgress
}

#derive(ProgressParams, serialize)

// ---- flang/serverStatus ----

pub type ProjectStatus = struct {
    name: String
    dir: String
    errors: usize
}

#derive(ProjectStatus, serialize)

pub type ServerStatus = struct {
    version: String
    folders: List(String)
    projects: List(ProjectStatus)
}

#derive(ServerStatus, serialize)

pub fn deinit(self: move ServerStatus) {
    self.folders.deinit()
    self.projects.deinit()
}

// ---- initialize ----

pub type TextDocumentSyncOptions = struct {
    open_close: bool
    change: i32
    save: bool
}

#derive(TextDocumentSyncOptions, serialize)

pub type CodeLensOptions = struct {
    resolve_provider: bool
}

#derive(CodeLensOptions, serialize)

pub type SignatureHelpOptions = struct {
    trigger_characters: String[]
}

#derive(SignatureHelpOptions, serialize)

pub type ServerCapabilities = struct {
    position_encoding: String
    text_document_sync: TextDocumentSyncOptions
    document_symbol_provider: bool
    folding_range_provider: bool
    workspace_symbol_provider: bool
    hover_provider: bool
    definition_provider: bool
    type_definition_provider: bool
    references_provider: bool
    inlay_hint_provider: bool
    document_formatting_provider: bool
    code_lens_provider: CodeLensOptions?
    signature_help_provider: SignatureHelpOptions
}

#derive(ServerCapabilities, serialize)

pub type ServerInfo = struct {
    name: String
    version: String
}

#derive(ServerInfo, serialize)

pub type InitializeResult = struct {
    capabilities: ServerCapabilities
    server_info: ServerInfo
}

#derive(InitializeResult, serialize)

// ---- Document features ----

pub type DocumentSymbol = struct {
    name: String
    kind: i32
    range: LspRange
    selection_range: LspRange
    children: List(DocumentSymbol)?
}

#derive(DocumentSymbol, serialize)

pub fn deinit(self: move DocumentSymbol) {
    self.children.deinit()
}

pub type FoldingRange = struct {
    start_line: usize
    end_line: usize
}

#derive(FoldingRange, serialize)

pub type SymbolInformation = struct {
    name: String
    kind: i32
    container_name: String?
    location: Location
}

#derive(SymbolInformation, serialize)

pub fn deinit(self: move SymbolInformation) {
    self.location.deinit()
}

pub type MarkupContent = struct {
    kind: String
    value: OwnedString
}

#derive(MarkupContent, serialize)

pub type Hover = struct {
    contents: MarkupContent
    range: LspRange
}

#derive(Hover, serialize)

pub fn deinit(self: move Hover) {
    self.contents.value.deinit()
}

pub type InlayHint = struct {
    position: Position
    label: OwnedString
    kind: i32
}

#derive(InlayHint, serialize)

pub fn deinit(self: move InlayHint) {
    self.label.deinit()
}

pub type ParameterInformation = struct {
    label: String
}

#derive(ParameterInformation, serialize)

pub type SignatureInformation = struct {
    label: String
    parameters: List(ParameterInformation)
}

#derive(SignatureInformation, serialize)

pub fn deinit(self: move SignatureInformation) {
    self.parameters.deinit()
}

pub type SignatureHelp = struct {
    signatures: List(SignatureInformation)
    active_signature: usize
    active_parameter: usize
}

#derive(SignatureHelp, serialize)

pub fn deinit(self: move SignatureHelp) {
    self.signatures.deinit()
}

pub type TextEdit = struct {
    range: LspRange
    new_text: String
}

#derive(TextEdit, serialize)

// ---- Code lens ----

// What `flang.runTest` runs: `flang test <file> --name <name>` from `dir`, `file` relative to it.
pub type TestTarget = struct {
    dir: String
    file: String
    name: String
}

#derive(TestTarget, serialize)

pub type RunTestCommand = struct {
    title: String
    command: String
    arguments: List(TestTarget)
}

#derive(RunTestCommand, serialize)

pub type CodeLens = struct {
    range: LspRange
    command: RunTestCommand
}

#derive(CodeLens, serialize)

pub fn deinit(self: move CodeLens) {
    self.command.arguments.deinit()
}
