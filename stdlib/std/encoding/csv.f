// CSV encoding, decoding, and table manipulation.
//
// Three separate components sharing a common SIMD classifier:
//
//   SIMD classifier  — shared core: classifies 16-byte chunks into delimiter bitmasks,
//                      computes quote parity via carryless multiply
//   CsvDecoder       — implements Decoder for #derive(T, deserialize);
//                      reads from a Reader, decodes fields directly without materializing records
//   CsvEncoder       — implements Encoder for #derive(T, serialize);
//                      writes CSV rows to a Writer
//   CsvReader        — reads entire file into memory, produces CsvRecord with String views;
//                      feeds CsvTable for column/row selection
//   CsvRecord        — single row with String views into a backing buffer
//   CsvTable         — materialized table owning its buffer, with select_columns/select_rows
//
// The parser handles RFC 4180 with lenient line endings (LF, CR, CRLF).
// Quoting and delimiter characters are configurable via CsvOptions.

import std.encoding.codec
import std.io.reader
import std.io.writer
import std.allocator
import std.conv
import std.enum
import std.interface
import std.list
import std.mem
import std.result
import std.string
import std.string_builder
import std.string_reader
import std.simd
import std.test
import core.bits

// =============================================================================
// Errors
// =============================================================================

pub type CsvError = enum {
    UnexpectedEnd
    InvalidQuoting
    IOError
}

#enum_utils(CsvError)

// =============================================================================
// Options
// =============================================================================

pub type CsvOptions = struct {
    delimiter: u8
    quote: u8
    has_headers: bool
}

pub fn csv_options() CsvOptions {
    return .{ delimiter = ',', quote = '"', has_headers = true }
}

// =============================================================================
// CsvRecord — single row with String views into a backing buffer
// =============================================================================

pub type CsvRecord = struct {
    fields: List(String)
    headers: &List(String)?
}

pub fn get(record: &CsvRecord, index: usize) String? {
    if index >= record.fields.len { return null }
    return record.fields[index]
}

pub fn get(record: &CsvRecord, name: String) String? {
    const hdrs = record.headers?
    for i in 0..hdrs.len {
        if hdrs[i] == name {
            return record.get(i)
        }
    }
    return null
}

pub fn field_count(record: &CsvRecord) usize {
    return record.fields.len
}

// =============================================================================
// SIMD classifier — shared core for delimiter detection
// =============================================================================

// Bitmasks for structural characters in a 16-byte chunk.
type ChunkMasks = struct {
    delimiters: u32
    quotes: u32
    newlines: u32
}

fn classify_chunk(chunk_ptr: &u8, delimiter: u8, quote: u8) ChunkMasks {
    const chunk = v128_load(chunk_ptr)
    const delim_mask = v128_movemask(v128_cmpeq_u8(chunk, v128_splat_u8(delimiter)))
    const quote_mask = v128_movemask(v128_cmpeq_u8(chunk, v128_splat_u8(quote)))
    const lf_mask = v128_movemask(v128_cmpeq_u8(chunk, v128_splat_u8(0x0A)))
    const cr_mask = v128_movemask(v128_cmpeq_u8(chunk, v128_splat_u8(0x0D)))
    return .{
        delimiters = delim_mask,
        quotes = quote_mask,
        newlines = lf_mask | cr_mask
    }
}

fn compute_quote_parity(quote_mask: u32, carry: u64) (u32, u64) {
    const effective_mask = quote_mask as u64
    const quote_vec = v128_from_u64(effective_mask)
    const all_ones = v128_from_u64(0xFFFF_FFFF_FFFF_FFFF)
    const parity_vec = v128_clmul(quote_vec, all_ones)

    let parity_out: [u8; 16] = [0; 16]
    v128_store(&parity_out[0], parity_vec)
    let parity_lo = parity_out[0] as u64 | ((parity_out[1] as u64) << 8)

    let result = parity_lo as u32
    const carry_bit = carry & 1
    if carry_bit == 1 {
        result = ~result
    }

    const new_carry = carry + count_ones_u32(quote_mask) as u64
    return (result & 0xFFFF, new_carry)
}

fn filter_by_quotes(masks: ChunkMasks, inside_quotes: u32) ChunkMasks {
    const outside = ~inside_quotes & 0xFFFF
    return .{
        delimiters = masks.delimiters & outside,
        quotes = masks.quotes,
        newlines = masks.newlines & outside
    }
}

// Field span within a buffer: [start, end) byte range.
type FieldSpan = struct {
    start: usize
    end: usize
}

// =============================================================================
// Shared row parsing — extracts field spans from a buffer
// =============================================================================

// Parse state for CsvDecoder's streaming row parser.
type ParseState = struct {
    quote_carry: u64
    prev_cr: bool
    in_quotes: bool
}

// Process a chunk of data, appending field content to field_buf and
// completed fields to spans. Returns the number of bytes consumed.
// Sets row_complete to true if a newline was found (end of row).
fn process_chunk(
    data: u8[], data_len: usize,
    options: &CsvOptions, state: &ParseState,
    field_buf: &StringBuilder, spans: &List(FieldSpan),
    field_start_offset: usize,
    row_complete: &bool
) usize {
    // Pad to 16 bytes for SIMD if needed
    let chunk_buf: [u8; 16] = [0; 16]
    let chunk_ptr = data.ptr
    if data_len < 16 {
        memcpy(&chunk_buf[0], data.ptr, data_len)
        chunk_ptr = &chunk_buf[0]
    }

    const masks = classify_chunk(chunk_ptr, options.delimiter, options.quote)
    const parity_result = compute_quote_parity(masks.quotes, state.quote_carry)
    const inside_quotes = parity_result.0
    state.quote_carry = parity_result.1
    const filtered = filter_by_quotes(masks, inside_quotes)

    const valid_mask = (1u32 << (data_len as u32)) - 1
    const quote_bits = masks.quotes & valid_mask

    let pos: usize = 0

    // Handle prev_cr + LF at start of chunk
    if state.prev_cr {
        state.prev_cr = false
        if data_len > 0 {
            if data[pos] == 0x0A {
                pos = 1
            }
        }
    }

    while pos < data_len {
        const byte = data[pos]
        const bit = 1u32 << (pos as u32)

        const is_newline = filtered.newlines & bit
        const is_delim = filtered.delimiters & bit
        const is_quote = quote_bits & bit

        if is_newline != 0 {
            if byte == 0x0D { state.prev_cr = true }
            // End current field and row
            let span: FieldSpan
            span.start = field_start_offset
            span.end = field_start_offset + field_buf.len
            spans.push(span)
            pos = pos + 1
            // Check for CRLF within chunk
            if state.prev_cr {
                if pos < data_len {
                    if data[pos] == 0x0A {
                        pos = pos + 1
                        state.prev_cr = false
                    }
                }
            }
            row_complete.* = true
            return pos
        } else if is_delim != 0 {
            // End current field
            let span: FieldSpan
            span.start = field_start_offset
            span.end = field_start_offset + field_buf.len
            spans.push(span)
            // Next field starts after what we've accumulated
            field_buf.clear()
            pos = pos + 1
        } else if is_quote != 0 {
            if state.in_quotes {
                if pos + 1 < data_len {
                    if data[pos + 1] == options.quote {
                        field_buf.append_byte(options.quote)
                        pos = pos + 2
                    } else {
                        state.in_quotes = false
                        pos = pos + 1
                    }
                } else {
                    state.in_quotes = false
                    pos = pos + 1
                }
            } else {
                state.in_quotes = true
                pos = pos + 1
            }
        } else {
            field_buf.append_byte(byte)
            pos = pos + 1
        }
    }

    return pos
}

// =============================================================================
// CsvDecoder — streaming decoder for #derive(T, deserialize)
// =============================================================================

pub type CsvDecoder = struct {
    reader: Reader
    chunk: [u8; 16]
    chunk_len: usize
    options: CsvOptions
    headers: List(String)
    header_buf: StringBuilder
    // Current row: field_buf accumulates bytes, spans mark boundaries
    field_buf: StringBuilder
    spans: List(FieldSpan)
    current_field: usize
    row_parsed: bool
    eof: bool
    error: CsvError?
    state: ParseState
}

pub fn csv_decoder_init(self: &CsvDecoder, r: Reader, options: CsvOptions = csv_options(), allocator: &Allocator? = null) {
    self.reader = r
    self.options = options
    self.headers = list(16, allocator)
    self.header_buf = string_builder(256, allocator)
    self.field_buf = string_builder(4096, allocator)
    self.spans = list(64, allocator)
}

fn fill_decoder_chunk(self: &CsvDecoder) {
    let dst = slice_from_raw_parts(&self.chunk[0], 16)
    const n = self.reader.read(dst)
    self.chunk_len = n
    if n == 0 { self.eof = true }
}

// Parse one row into field_buf + spans.
fn parse_decoder_row(self: &CsvDecoder) bool {
    self.field_buf.clear()
    self.spans.clear()

    loop {
        if self.chunk_len == 0 {
            self.fill_decoder_chunk()
            if self.eof {
                if self.field_buf.len > 0 {
                    let span: FieldSpan
                    span.start = 0
                    span.end = self.field_buf.len
                    self.spans.push(span)
                    return true
                }
                return self.spans.len > 0
            }
        }

        let row_complete = false
        // field_start_offset: where the current field's data starts in field_buf
        // For spans, we track relative to field_buf. But since process_chunk
        // clears field_buf between fields, we need a different approach.
        // Instead: accumulate ALL field data into field_buf with a separator,
        // and track spans as absolute offsets into field_buf.
        const chunk_slice = slice_from_raw_parts(&self.chunk[0], self.chunk_len)
        const consumed = process_chunk(
            chunk_slice, self.chunk_len,
            &self.options, &self.state,
            &self.field_buf, &self.spans,
            self.field_buf.len,
            &row_complete
        )

        if row_complete {
            // Shift remaining bytes
            if consumed < self.chunk_len {
                const remaining = self.chunk_len - consumed
                let src_pos = consumed
                for i in 0..remaining {
                    self.chunk[i] = self.chunk[src_pos]
                    src_pos = src_pos + 1
                }
                self.chunk_len = remaining
            } else {
                self.chunk_len = 0
            }
            self.state.quote_carry = 0
            return true
        } else {
            self.chunk_len = 0
        }
    }
    return false
}

// Get field value as String view into field_buf for the current row.
fn get_decoder_field(self: &CsvDecoder, index: usize) String {
    if index >= self.spans.len {
        return ""
    }
    const span = self.spans[index]
    if span.end <= span.start { return "" }
    const len = span.end - span.start
    const ptr = self.field_buf.ptr + span.start
    return .{ ptr = ptr, len = len } as String
}

// Parse headers on first call
fn ensure_decoder_headers(self: &CsvDecoder) {
    if self.headers.len > 0 { return }
    if self.options.has_headers == false { return }

    if self.parse_decoder_row() {
        // Copy header values into header_buf so they persist
        for i in 0..self.spans.len {
            const field_val = self.get_decoder_field(i)
            self.header_buf.append(field_val)
            // String views resolved after all headers are added
        }
        // Now create String views into header_buf
        const buf_ptr = self.header_buf.ptr
        let offset: usize = 0
        for i in 0..self.spans.len {
            const span = self.spans[i]
            const len = span.end - span.start
            const view = .{ ptr = buf_ptr + offset, len = len } as String
            self.headers.push(view)
            offset = offset + len
        }
    }
}

// Decoder interface implementation

pub fn decode_null(self: &CsvDecoder) bool { return true }

pub fn decode_bool(self: &CsvDecoder) bool {
    if self.current_field >= self.spans.len { return false }
    const val = self.get_decoder_field(self.current_field)
    self.current_field = self.current_field + 1
    if val == "true" { return true }
    if val == "1" { return true }
    return false
}

pub fn decode_int(self: &CsvDecoder, width: u8) i64 {
    if self.current_field >= self.spans.len { return 0 }
    const val = self.get_decoder_field(self.current_field)
    self.current_field = self.current_field + 1
    if val.len == 0 { return 0 }
    const parsed = parse_i64(val)
    if parsed.is_ok() { return parsed.unwrap().0 }
    return 0
}

pub fn decode_uint(self: &CsvDecoder, width: u8) u64 {
    if self.current_field >= self.spans.len { return 0 }
    const val = self.get_decoder_field(self.current_field)
    self.current_field = self.current_field + 1
    if val.len == 0 { return 0 }
    const parsed = parse_u64(val)
    if parsed.is_ok() { return parsed.unwrap().0 }
    return 0
}

pub fn decode_float(self: &CsvDecoder, width: u8) f64 {
    if self.current_field >= self.spans.len { return 0.0 }
    const val = self.get_decoder_field(self.current_field)
    self.current_field = self.current_field + 1
    if val.len == 0 { return 0.0 }
    const parsed = parse_f64(val)
    if parsed.is_ok() { return parsed.unwrap().0 }
    return 0.0
}

pub fn decode_str(self: &CsvDecoder, w: Writer) bool {
    if self.current_field >= self.spans.len { return false }
    const val = self.get_decoder_field(self.current_field)
    self.current_field = self.current_field + 1
    w.write_str(val)
    return true
}

pub fn decode_bytes(self: &CsvDecoder, w: Writer) bool {
    return self.decode_str(w)
}

pub fn begin_seq(self: &CsvDecoder) usize { return 0 }
pub fn end_seq(self: &CsvDecoder) bool { return true }

pub fn begin_map(self: &CsvDecoder) usize {
    self.ensure_decoder_headers()
    if self.row_parsed == false {
        self.parse_decoder_row()
        self.row_parsed = true
    }
    self.current_field = 0
    return self.spans.len
}

pub fn end_map(self: &CsvDecoder) bool {
    self.row_parsed = false
    return true
}

pub fn next_key(self: &CsvDecoder, sb: &StringBuilder) bool {
    if self.current_field >= self.headers.len { return false }
    sb.append(self.headers[self.current_field])
    return true
}

pub fn skip_value(self: &CsvDecoder) bool {
    self.current_field = self.current_field + 1
    return true
}

pub fn has_error(self: &CsvDecoder) bool { return self.error.is_some() }

pub fn deinit(self: &CsvDecoder) {
    self.field_buf.deinit()
    self.header_buf.deinit()
}

#implement(CsvDecoder, Decoder)

// =============================================================================
// CsvEncoder — streaming CSV writer for #derive(T, serialize)
// =============================================================================

pub type CsvEncoder = struct {
    w: Writer
    options: CsvOptions
    header_written: bool
    field_index: usize
    current_keys: List(OwnedString)
    first_row_values: List(OwnedString)
    row_count: usize
}

pub fn csv_encoder(w: Writer, options: CsvOptions = csv_options()) CsvEncoder {
    let enc: CsvEncoder
    enc.w = w
    enc.options = options
    let keys = list(16)
    enc.current_keys = keys
    let vals = list(16)
    enc.first_row_values = vals
    return enc
}

fn needs_quoting(self: &CsvEncoder, s: String) bool {
    for i in 0..s.len {
        const c = s[i]
        if c == self.options.delimiter { return true }
        if c == self.options.quote { return true }
        if c == 0x0A { return true }
        if c == 0x0D { return true }
    }
    return false
}

fn write_csv_field(self: &CsvEncoder, s: String) {
    if self.field_index > 0 {
        self.w.write_byte(self.options.delimiter)
    }
    if self.needs_quoting(s) {
        self.w.write_byte(self.options.quote)
        for i in 0..s.len {
            const c = s[i]
            if c == self.options.quote {
                self.w.write_byte(self.options.quote)
            }
            self.w.write_byte(c)
        }
        self.w.write_byte(self.options.quote)
    } else {
        self.w.write_str(s)
    }
    self.field_index = self.field_index + 1
}

pub fn encode_null(self: &CsvEncoder) usize {
    self.write_enc_value("")
    return 0
}

pub fn encode_bool(self: &CsvEncoder, v: bool) usize {
    if v { self.write_enc_value("true") }
    else { self.write_enc_value("false") }
    return 0
}

pub fn encode_int(self: &CsvEncoder, v: i64, width: u8) usize {
    let buf = [0u8; 21]
    const len = format_i64(v, buf).unwrap()
    const view = .{ ptr = &buf[0], len = len } as String
    self.write_enc_value(view)
    return 0
}

pub fn encode_uint(self: &CsvEncoder, v: u64, width: u8) usize {
    let buf = [0u8; 21]
    const len = format_u64(v, buf).unwrap()
    const view = .{ ptr = &buf[0], len = len } as String
    self.write_enc_value(view)
    return 0
}

pub fn encode_float(self: &CsvEncoder, v: f64, width: u8) usize {
    let sb = string_builder(32)
    sb.append(v)
    self.write_enc_value(sb.as_view())
    sb.deinit()
    return 0
}

pub fn encode_str(self: &CsvEncoder, v: String) usize {
    self.write_enc_value(v)
    return 0
}

pub fn encode_bytes(self: &CsvEncoder, v: u8[]) usize {
    const view = .{ ptr = v.ptr, len = v.len } as String
    self.write_enc_value(view)
    return 0
}

fn write_enc_value(self: &CsvEncoder, v: String) {
    if self.header_written == false {
        let owned = from_view(v, null)
        self.first_row_values.push(owned)
    } else {
        self.write_csv_field(v)
    }
}

pub fn begin_seq(self: &CsvEncoder, len: usize) usize { return 0 }
pub fn end_seq(self: &CsvEncoder) usize { return 0 }

pub fn begin_map(self: &CsvEncoder, len: usize) usize {
    self.field_index = 0
    return 0
}

pub fn end_map(self: &CsvEncoder) usize {
    if self.header_written == false {
        self.header_written = true
        for i in 0..self.current_keys.len {
            if i > 0 { self.w.write_byte(self.options.delimiter) }
            self.w.write_str(self.current_keys[i].as_view())
        }
        self.w.write_byte(0x0A)
        for i in 0..self.first_row_values.len {
            if i > 0 { self.w.write_byte(self.options.delimiter) }
            const val = self.first_row_values[i].as_view()
            self.field_index = i
            self.write_csv_field(val)
        }
        self.first_row_values.deinit()
        let empty_vals = list(0)
        self.first_row_values = empty_vals
    }
    self.w.write_byte(0x0A)
    self.row_count = self.row_count + 1
    self.field_index = 0
    return 0
}

pub fn key(self: &CsvEncoder, name: String) usize {
    if self.header_written == false {
        let owned = from_view(name, null)
        self.current_keys.push(owned)
    }
    return 0
}

pub fn is_human_readable(self: &CsvEncoder) bool { return true }

#implement(CsvEncoder, Encoder)

pub fn deinit(self: &CsvEncoder) {
    for i in 0..self.current_keys.len {
        self.current_keys[i].deinit()
    }
    self.current_keys.deinit()
}

// =============================================================================
// CsvReader — reads entire file into memory, produces CsvRecord with String views
// =============================================================================

pub type CsvReader = struct {
    buffer: StringBuilder
    options: CsvOptions
    headers: List(String)
    rows: List(CsvRecord)
    parsed: bool
}

pub fn csv_reader_init(self: &CsvReader, r: Reader, options: CsvOptions = csv_options(), allocator: &Allocator? = null) {
    self.options = options
    self.buffer = string_builder(4096, allocator)
    self.headers = list(16, allocator)

    // Read entire input into buffer
    let chunk: [u8; 4096] = [0; 4096]
    loop {
        let dst = slice_from_raw_parts(&chunk[0], 4096)
        const n = r.read(dst)
        if n == 0 { break }
        const data = slice_from_raw_parts(&chunk[0], n)
        self.buffer.append_bytes(data)
    }
}

// SIMD-accelerated parser for in-memory buffer.
// Uses classify_chunk to find delimiters in 16-byte batches,
// then extracts field boundaries as String views into self.buffer.
fn parse_all(self: &CsvReader) {
    if self.parsed { return }
    self.parsed = true

    const data = self.buffer.as_view()
    const data_ptr = data.ptr
    const data_len = data.len
    let pos: usize = 0
    let quote_carry: u64 = 0
    let field_start: usize = 0

    // --- Parse headers ---
    if self.options.has_headers {
        field_start = 0
        while pos < data_len {
            const remaining = data_len - pos
            const chunk_size = if remaining < 16 { remaining } else { 16usize }

            // SIMD classify
            let chunk_buf: [u8; 16] = [0; 16]
            if chunk_size < 16 {
                memcpy(&chunk_buf[0], data_ptr + pos, chunk_size)
            }
            const cptr = if chunk_size < 16 { &chunk_buf[0] } else { data_ptr + pos }
            const masks = classify_chunk(cptr, self.options.delimiter, self.options.quote)
            const parity = compute_quote_parity(masks.quotes, quote_carry)
            const inside = parity.0
            quote_carry = parity.1
            const filtered = filter_by_quotes(masks, inside)
            const valid = (1u32 << (chunk_size as u32)) - 1

            // Scan structural bits
            let structural = (filtered.delimiters | filtered.newlines) & valid
            let header_done = false
            loop {
                if structural == 0 { break }
                const bit_pos = trailing_zeros_u32(structural) as usize
                const abs_pos = pos + bit_pos
                const byte = data[abs_pos]

                if byte == 0x0A or byte == 0x0D {
                    self.headers.push(self.extract_field(data, field_start, abs_pos))
                    let next = abs_pos + 1
                    if byte == 0x0D {
                        if next < data_len {
                            if data[next] == 0x0A { next = next + 1 }
                        }
                    }
                    pos = next
                    field_start = next
                    quote_carry = 0
                    header_done = true
                    break
                } else {
                    // Delimiter
                    self.headers.push(self.extract_field(data, field_start, abs_pos))
                    field_start = abs_pos + 1
                }
                structural = structural & (structural - 1)
            }
            if header_done { break }
            if structural == 0 {
                pos = pos + chunk_size
            }
        }
    }

    // --- Parse data rows ---
    let rows = list(64)
    field_start = pos
    let current_fields = list(16)
    let pad_buf: [u8; 16] = [0; 16]

    loop {
        if pos >= data_len {
            // EOF — flush remaining field
            if field_start < data_len {
                current_fields.push(self.extract_field(data, field_start, data_len))
                let rec: CsvRecord
                rec.headers = &self.headers
                rec.fields = current_fields
                rows.push(rec)
            }
            break
        }

        const remaining = data_len - pos
        // For the last partial chunk, copy to padded buffer
        const is_partial = remaining < 16
        const chunk_size = if is_partial { remaining } else { 16usize }
        let cptr = data_ptr + pos
        if is_partial {
            memcpy(&pad_buf[0], cptr, chunk_size)
            cptr = &pad_buf[0]
        }

        const masks = classify_chunk(cptr, self.options.delimiter, self.options.quote)

        // Compute structural character mask, filtering out delimiters inside quotes
        let structural: u32 = 0
        const valid = (1u32 << (chunk_size as u32)) - 1
        const carry_odd = (quote_carry & 1) == 1
        const has_quotes = masks.quotes != 0
        if has_quotes or carry_odd {
            // Need full quote parity computation
            const parity = compute_quote_parity(masks.quotes, quote_carry)
            const inside = parity.0
            quote_carry = parity.1
            const filtered = filter_by_quotes(masks, inside)
            structural = (filtered.delimiters | filtered.newlines) & valid
        } else {
            // No quotes anywhere — all delimiters are real
            structural = (masks.delimiters | masks.newlines) & valid
        }

        if structural == 0 {
            pos = pos + chunk_size
            continue
        }

        // Process ALL structural characters in this chunk
        while structural != 0 {
            const bit_pos = trailing_zeros_u32(structural) as usize
            const abs_pos = pos + bit_pos
            const byte = data[abs_pos]

            if byte == 0x0A or byte == 0x0D {
                current_fields.push(self.extract_field(data, field_start, abs_pos))
                let rec: CsvRecord
                rec.headers = &self.headers
                rec.fields = current_fields
                rows.push(rec)

                current_fields = list(16)

                field_start = abs_pos + 1
                if byte == 0x0D {
                    if field_start < data_len {
                        if data[field_start] == 0x0A { field_start = field_start + 1 }
                    }
                }
            } else {
                current_fields.push(self.extract_field(data, field_start, abs_pos))
                field_start = abs_pos + 1
            }
            structural = structural & (structural - 1)
        }

        pos = pos + chunk_size
    }

    self.rows = rows
}

// Extract a field value from the buffer between start and end.
// Strips surrounding quotes and unescapes doubled quotes.
fn extract_field(self: &CsvReader, data: String, start: usize, end: usize) String {
    if start >= end { return "" }
    // Fast path: unquoted field — just a pointer+length view (vast majority of fields)
    if data[start] != self.options.quote {
        return .{ ptr = data.ptr + start, len = end - start } as String
    }
    // Quoted field — strip surrounding quotes
    const quote = self.options.quote
    if end > start + 1 {
        if data[end - 1] == quote {
            const len = end - start - 2
            if len == 0 { return "" }
            // TODO: unescape doubled quotes into a separate buffer
            return .{ ptr = data.ptr + start + 1usize, len = len } as String
        }
    }
    // Fallback — return as-is
    return .{ ptr = data.ptr + start, len = end - start } as String
}

pub fn get_headers(self: &CsvReader) &List(String) {
    self.parse_all()
    return &self.headers
}

pub fn get_rows(self: &CsvReader) &List(CsvRecord) {
    self.parse_all()
    return &self.rows
}

pub fn row_count(self: &CsvReader) usize {
    self.parse_all()
    return self.rows.len
}

pub fn deinit(self: &CsvReader) {
    self.buffer.deinit()
}

// =============================================================================
// CsvTable — materialized table owning its buffer
// =============================================================================

pub type CsvTable = struct {
    headers: List(String)
    rows: List(CsvRecord)
    buffer: StringBuilder
}

pub fn csv_table(r: Reader, options: CsvOptions = csv_options(), allocator: &Allocator? = null) Result(CsvTable, CsvError) {
    let reader: CsvReader
    csv_reader_init(&reader, r, options, allocator)
    reader.parse_all()

    let table: CsvTable
    table.headers = reader.headers
    table.rows = reader.rows
    table.buffer = reader.buffer
    // Don't deinit reader — table took ownership of buffer
    return Result.Ok(table)
}

pub fn deinit(table: &CsvTable) {
    table.buffer.deinit()
}

pub fn row_count(table: &CsvTable) usize {
    return table.rows.len
}

pub fn column_count(table: &CsvTable) usize {
    return table.headers.len
}

pub fn select_rows(table: &CsvTable, start: usize, end: usize) CsvTable {
    let result: CsvTable
    result.buffer = string_builder(0)

    // Share headers (String views — still valid as long as original table lives)
    let sel_headers = list(table.headers.len)
    for i in 0..table.headers.len {
        sel_headers.push(table.headers[i])
    }
    result.headers = sel_headers

    const actual_end = if end > table.rows.len { table.rows.len } else { end }
    const actual_start = if start > actual_end { actual_end } else { start }
    let sel_rows = list(actual_end - actual_start)
    for i in actual_start..actual_end {
        const src = table.rows[i]
        let rec: CsvRecord
        let copied_fields = list(src.fields.len)
        for fi in 0..src.fields.len {
            copied_fields.push(src.fields[fi])
        }
        rec.fields = copied_fields
        rec.headers = &result.headers
        sel_rows.push(rec)
    }
    result.rows = sel_rows

    return result
}

pub fn select_columns(table: &CsvTable, names: String[]) CsvTable {
    let result: CsvTable
    result.buffer = string_builder(0)

    // Find column indices
    let indices = list(names.len)
    for n in 0..names.len {
        for i in 0..table.headers.len {
            if table.headers[i] == names[n] {
                indices.push(i)
                break
            }
        }
    }

    // Copy selected headers
    let col_headers = list(indices.len)
    for i in 0..indices.len {
        const idx = indices[i]
        col_headers.push(table.headers[idx])
    }
    result.headers = col_headers

    // Copy rows with selected columns
    let col_rows = list(table.rows.len)
    for r in 0..table.rows.len {
        const src = table.rows[r]
        let rec: CsvRecord
        rec.headers = &result.headers
        let rec_fields = list(indices.len)
        for j in 0..indices.len {
            const idx = indices[j]
            if idx < src.fields.len {
                rec_fields.push(src.fields[idx])
            } else {
                rec_fields.push("")
            }
        }
        rec.fields = rec_fields
        col_rows.push(rec)
    }
    result.rows = col_rows

    indices.deinit()
    return result
}

// =============================================================================
// Tests
// =============================================================================

test "parse simple CSV" {
    const input = "a\n1\n"
    let mr = mem_reader(input)
    let reader: CsvReader
    csv_reader_init(&reader, mr.reader())
    reader.parse_all()
    assert_eq(reader.row_count(), 1usize, "1 row")
    const rows = reader.get_rows()
    assert_eq(rows[0].get(0usize).unwrap(), "1", "field 0")
    reader.deinit()
}

test "parse CSV with quoted fields" {
    const input = "name,city\n\"Alice, Jr.\",\"New York\"\nBob,London\n"
    let mr = mem_reader(input)
    let reader: CsvReader
    csv_reader_init(&reader, mr.reader())
    reader.parse_all()
    assert_eq(reader.row_count(), 2usize, "2 rows")
    reader.deinit()
}

test "get by index" {
    const input = "a,b,c\n1,2,3\n"
    let mr = mem_reader(input)
    let reader: CsvReader
    csv_reader_init(&reader, mr.reader())
    reader.parse_all()
    const rows = reader.get_rows()
    assert_eq(rows[0].get(0usize).unwrap(), "1", "index 0")
    assert_eq(rows[0].get(1usize).unwrap(), "2", "index 1")
    assert_eq(rows[0].get(2usize).unwrap(), "3", "index 2")
    assert_true(rows[0].get(3usize).is_none(), "index 3 out of bounds")
    reader.deinit()
}

test "CRLF line endings" {
    const input = "a,b\r\n1,2\r\n3,4\r\n"
    let mr = mem_reader(input)
    let reader: CsvReader
    csv_reader_init(&reader, mr.reader())
    const hdrs = reader.get_headers()
    assert_eq(hdrs.len, 2usize, "2 headers")
    assert_eq(hdrs[0], "a", "header a")
    reader.deinit()
}

test "CR only line endings" {
    const input = "a,b\r1,2\r3,4\r"
    let mr = mem_reader(input)
    let reader: CsvReader
    csv_reader_init(&reader, mr.reader())
    const hdrs = reader.get_headers()
    assert_eq(hdrs.len, 2usize, "2 headers")
    assert_eq(hdrs[0], "a", "header a")
    reader.deinit()
}
