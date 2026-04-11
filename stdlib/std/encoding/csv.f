// CSV encoding, decoding, and table manipulation.
//
//   CsvReader  — implements Decoder for CSV input from a Reader;
//                SIMD-accelerated delimiter detection
//   CsvWriter  — implements Encoder for CSV output to a Writer
//   CsvRecord  — single row with get-by-name and get-by-index
//   CsvTable   — materialized table with column/row selection
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
    return .{ delimiter = b',', quote = b'"', has_headers = true }
}

// =============================================================================
// CsvRecord — single parsed row
// =============================================================================

pub type CsvRecord = struct {
    fields: List(OwnedString)
    headers: &List(OwnedString)?
}

pub fn get(record: &CsvRecord, index: usize) String? {
    if index >= record.fields.len { return null }
    return record.fields.as_slice()[index].as_view()
}

pub fn get(record: &CsvRecord, name: String) String? {
    if record.headers.is_none() { return null }
    const hdrs = record.headers.value
    for (i in 0..hdrs.len) {
        if hdrs.as_slice()[i].as_view() == name {
            return record.get(i)
        }
    }
    return null
}

pub fn field_count(record: &CsvRecord) usize {
    return record.fields.len
}

// =============================================================================
// CsvTable — materialized table with arena-owned strings
// =============================================================================

pub type CsvTable = struct {
    headers: List(OwnedString)
    rows: List(CsvRecord)
    arena: ArenaAllocatorState
}

pub fn deinit(table: &CsvTable) {
    table.arena.deinit()
}

pub fn row_count(table: &CsvTable) usize {
    return table.rows.len
}

pub fn column_count(table: &CsvTable) usize {
    return table.headers.len
}

// =============================================================================
// Internal helpers
// =============================================================================

fn write_byte(w: Writer, b: u8) {
    let byte = b
    w.write(slice_from_raw_parts(&byte, 1))
}

fn write_str(w: Writer, s: String) {
    w.write(slice_from_raw_parts(s.ptr, s.len))
}

// =============================================================================
// SIMD classifier — find delimiters in 16-byte chunks
// =============================================================================

// Classify a 16-byte chunk. Returns bitmasks for structural characters.
// Bits in each mask correspond to byte positions in the chunk.
type ChunkMasks = struct {
    delimiters: u32   // comma (or custom delimiter) positions
    quotes: u32       // quote character positions
    newlines: u32     // LF or CR positions
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

// Compute prefix XOR to determine which positions are inside quoted fields.
// Returns a bitmask where bit=1 means "inside quotes".
fn compute_quote_parity(quote_mask: u32, carry: u64) (u32, u64) {
    // Combine carry with current quote mask.
    // If carry is odd (we entered this chunk inside quotes), flip all bits.
    const effective_mask = quote_mask as u64

    // Prefix XOR via carryless multiply: clmul(quotes, all_ones) gives
    // the running XOR parity at each position.
    const quote_vec = v128_from_u64(effective_mask)
    const all_ones = v128_from_u64(0xFFFF_FFFF_FFFF_FFFF)
    const parity_vec = v128_clmul(quote_vec, all_ones)

    // Extract low 64 bits — we only need the low 16 bits for a 16-byte chunk
    let parity_out: [u8; 16] = [0; 16]
    v128_store(&parity_out[0], parity_vec)
    let parity_lo: u64 = 0
    // Read first 2 bytes as u16 (little-endian)
    parity_lo = parity_out[0] as u64 | ((parity_out[1] as u64) << 8)

    // Apply carry: if we entered inside quotes, flip the parity
    let result = parity_lo as u32
    const carry_bit = carry & 1
    if carry_bit == 1 {
        result = result ^ 0xFFFF
    }

    // New carry: total quote count parity (odd = still inside)
    const new_carry = carry + count_ones_u32(quote_mask) as u64

    return (result & 0xFFFF, new_carry)
}

// Filter out structural characters that are inside quoted fields.
fn filter_by_quotes(masks: ChunkMasks, inside_quotes: u32) ChunkMasks {
    const outside = (inside_quotes ^ 0xFFFF) & 0xFFFF
    return .{
        delimiters = masks.delimiters & outside,
        quotes = masks.quotes,
        newlines = masks.newlines & outside
    }
}

// =============================================================================
// CsvReader — streaming row reader with SIMD parsing
// =============================================================================

pub type CsvReader = struct {
    reader: Reader
    chunk: [u8; 16]
    chunk_len: usize
    options: CsvOptions
    headers: List(OwnedString)
    current_field: usize
    row_fields: List(OwnedString)
    field_buf: StringBuilder
    row_parsed: bool
    eof: bool
    error: CsvError?
    arena: ArenaAllocatorState
    quote_carry: u64
    // State for tracking CR in CRLF sequences
    prev_cr: bool
}

pub fn csv_reader(r: Reader, options: CsvOptions = csv_options()) CsvReader {
    let reader: CsvReader
    reader.reader = r
    reader.options = options
    let headers: List(OwnedString) = list(16)
    reader.headers = headers
    let row_fields: List(OwnedString) = list(16)
    reader.row_fields = row_fields
    reader.field_buf = string_builder(256)
    reader.arena = arena_allocator(&global_allocator)
    return reader
}

fn fill_chunk(self: &CsvReader) {
    let dst = slice_from_raw_parts(&self.chunk[0], 16)
    const n = self.reader.read(dst)
    self.chunk_len = n
    if n == 0 {
        self.eof = true
    }
}

// Parse one complete row from the input stream.
// Returns true if a row was parsed, false at EOF.
fn parse_row(self: &CsvReader) bool {
    self.row_fields.clear()
    self.field_buf.clear()
    let in_quotes = false

    loop {
        if self.chunk_len == 0 {
            self.fill_chunk()
            if self.eof {
                // Flush remaining field if we have content
                if self.field_buf.len > 0 {
                    const arena_alloc = self.arena.allocator()
                    const field = from_view(self.field_buf.as_view(), &arena_alloc)
                    self.row_fields.push(field)
                    return true
                }
                return self.row_fields.len > 0
            }
        }

        // Pad chunk to 16 bytes with zeros if partial
        if self.chunk_len < 16 {
            for (i in self.chunk_len..16) {
                self.chunk[i] = 0
            }
        }

        // SIMD classify
        const masks = classify_chunk(&self.chunk[0], self.options.delimiter, self.options.quote)
        const parity_result = compute_quote_parity(masks.quotes, self.quote_carry)
        const inside_quotes = parity_result._0
        self.quote_carry = parity_result._1
        const filtered = filter_by_quotes(masks, inside_quotes)

        // Mask to valid chunk length
        const valid_mask = (1u32 << (self.chunk_len as u32)) - 1
        const quote_bits = masks.quotes & valid_mask

        // Process byte by byte within this chunk, using the bitmasks to identify structure
        let pos: usize = 0
        let found_newline = false

        // Handle prev_cr + current chunk starts with LF → skip the LF
        if self.prev_cr {
            self.prev_cr = false
            if self.chunk_len > 0 {
                if self.chunk[0] == 0x0A {
                    pos = 1
                }
            }
        }

        loop {
            if pos >= self.chunk_len { break }

            const byte = self.chunk[pos]
            const bit = 1u32 << (pos as u32)

            const is_newline = filtered.newlines & bit
            const is_delim = filtered.delimiters & bit
            const is_quote = quote_bits & bit

            if is_newline != 0 {
                // Real newline (outside quotes)
                if byte == 0x0D {
                    self.prev_cr = true
                }
                // Flush current field
                const arena_alloc = self.arena.allocator()
                const field = from_view(self.field_buf.as_view(), &arena_alloc)
                self.row_fields.push(field)
                self.field_buf.clear()
                found_newline = true
                // Consume remaining bytes after newline as next chunk's start
                pos = pos + 1
                // Check for CRLF within chunk
                if self.prev_cr {
                    if pos < self.chunk_len {
                        if self.chunk[pos] == 0x0A {
                            pos = pos + 1
                            self.prev_cr = false
                        }
                    }
                }
                break
            } else if is_delim != 0 {
                // Real delimiter (outside quotes)
                const arena_alloc = self.arena.allocator()
                const field = from_view(self.field_buf.as_view(), &arena_alloc)
                self.row_fields.push(field)
                self.field_buf.clear()
                pos = pos + 1
            } else if is_quote != 0 {
                // Quote character — toggle in_quotes state
                // For escaped quotes (""), the second quote re-enters the field
                // Check if next byte is also a quote (escaped)
                if in_quotes {
                    if pos + 1 < self.chunk_len {
                        if self.chunk[pos + 1] == self.options.quote {
                            // Escaped quote — emit one quote character
                            self.field_buf.append_byte(self.options.quote)
                            pos = pos + 2
                        } else {
                            // End of quoted field
                            in_quotes = false
                            pos = pos + 1
                        }
                    } else {
                        // Quote at end of chunk — need more data to decide
                        in_quotes = false
                        pos = pos + 1
                    }
                } else {
                    // Start of quoted field
                    in_quotes = true
                    pos = pos + 1
                }
            } else {
                // Regular character
                self.field_buf.append_byte(byte)
                pos = pos + 1
            }
        }

        // Update chunk: shift remaining bytes or clear
        if found_newline {
            if pos < self.chunk_len {
                // Shift remaining bytes to start of chunk
                const remaining = self.chunk_len - pos
                let src_pos = pos
                for (i in 0..remaining) {
                    self.chunk[i] = self.chunk[src_pos]
                    src_pos = src_pos + 1
                }
                self.chunk_len = remaining
            } else {
                self.chunk_len = 0
            }
            // Reset quote carry for new row
            self.quote_carry = 0
            return true
        } else {
            // Consumed entire chunk, need more data
            self.chunk_len = 0
        }
    }
    return false
}

// Read the next record from the CSV stream.
// On first call, parses headers if has_headers is true.
pub fn next_record(self: &CsvReader) CsvRecord? {
    if self.eof {
        if self.row_fields.len > 0 {
            // Already returned last row
        }
        return null
    }

    // Parse headers on first call
    if self.options.has_headers {
        if self.headers.len == 0 {
            if self.parse_row() == false { return null }
            // Move parsed fields to headers
            for (i in 0..self.row_fields.len) {
                self.headers.push(self.row_fields.as_slice()[i])
            }
            self.row_fields.clear()
        }
    }

    // Parse next data row
    if self.parse_row() == false { return null }

    let record: CsvRecord
    record.fields = self.row_fields
    record.headers = &self.headers
    // Create a new list for next row's fields
    let new_fields: List(OwnedString) = list(16)
    self.row_fields = new_fields
    return record
}

pub fn get_headers(self: &CsvReader) &List(OwnedString) {
    return &self.headers
}

pub fn has_error(self: &CsvReader) bool {
    return self.error.is_some()
}

pub fn deinit(self: &CsvReader) {
    self.field_buf.deinit()
    self.arena.deinit()
}

// =============================================================================
// CsvReader as Decoder (for #derive(T, deserialize) support)
// =============================================================================

pub fn decode_null(self: &CsvReader) bool {
    return true
}

pub fn decode_bool(self: &CsvReader) bool {
    if self.current_field >= self.row_fields.len { return false }
    const val = self.row_fields.as_slice()[self.current_field].as_view()
    self.current_field = self.current_field + 1
    if val == "true" { return true }
    if val == "1" { return true }
    return false
}

pub fn decode_int(self: &CsvReader, width: u8) i64 {
    if self.current_field >= self.row_fields.len { return 0 }
    const val = self.row_fields.as_slice()[self.current_field].as_view()
    self.current_field = self.current_field + 1
    if val.len == 0 { return 0 }
    const parsed = parse_i64(val)
    if parsed.is_ok() { return parsed.unwrap()._0 }
    return 0
}

pub fn decode_uint(self: &CsvReader, width: u8) u64 {
    if self.current_field >= self.row_fields.len { return 0 }
    const val = self.row_fields.as_slice()[self.current_field].as_view()
    self.current_field = self.current_field + 1
    if val.len == 0 { return 0 }
    const parsed = parse_u64(val)
    if parsed.is_ok() { return parsed.unwrap()._0 }
    return 0
}

pub fn decode_float(self: &CsvReader, width: u8) f64 {
    if self.current_field >= self.row_fields.len { return 0.0 }
    const val = self.row_fields.as_slice()[self.current_field].as_view()
    self.current_field = self.current_field + 1
    if val.len == 0 { return 0.0 }
    const parsed = parse_f64(val)
    if parsed.is_ok() { return parsed.unwrap()._0 }
    return 0.0
}

pub fn decode_str(self: &CsvReader, w: Writer) bool {
    if self.current_field >= self.row_fields.len { return false }
    const val = self.row_fields.as_slice()[self.current_field].as_view()
    self.current_field = self.current_field + 1
    write_str(w, val)
    return true
}

pub fn decode_bytes(self: &CsvReader, w: Writer) bool {
    return self.decode_str(w)
}

pub fn begin_seq(self: &CsvReader) usize { return 0 }
pub fn end_seq(self: &CsvReader) bool { return true }

pub fn begin_map(self: &CsvReader) usize {
    // Parse next row for Decoder interface usage
    if self.row_parsed == false {
        // On first call, parse headers
        if self.options.has_headers {
            if self.headers.len == 0 {
                if self.parse_row() {
                    for (i in 0..self.row_fields.len) {
                        self.headers.push(self.row_fields.as_slice()[i])
                    }
                    self.row_fields.clear()
                }
            }
        }
        self.parse_row()
        self.row_parsed = true
    }
    self.current_field = 0
    return self.row_fields.len
}

pub fn end_map(self: &CsvReader) bool {
    self.row_parsed = false
    return true
}

pub fn next_key(self: &CsvReader, sb: &StringBuilder) bool {
    if self.current_field >= self.headers.len { return false }
    const key = self.headers.as_slice()[self.current_field].as_view()
    sb.append(key)
    return true
}

pub fn skip_value(self: &CsvReader) bool {
    self.current_field = self.current_field + 1
    return true
}

#implement(CsvReader, Decoder)

// =============================================================================
// CsvWriter — streaming row writer
// =============================================================================

pub type CsvWriter = struct {
    w: Writer
    options: CsvOptions
    header_written: bool
    field_index: usize
    current_keys: List(OwnedString)
    first_row_values: List(OwnedString)
    row_count: usize
}

pub fn csv_writer(w: Writer, options: CsvOptions = csv_options()) CsvWriter {
    let writer: CsvWriter
    writer.w = w
    writer.options = options
    let keys: List(OwnedString) = list(16)
    writer.current_keys = keys
    let vals: List(OwnedString) = list(16)
    writer.first_row_values = vals
    return writer
}

fn needs_quoting(self: &CsvWriter, s: String) bool {
    for (i in 0..s.len) {
        const c = s[i]
        if c == self.options.delimiter { return true }
        if c == self.options.quote { return true }
        if c == 0x0A { return true }
        if c == 0x0D { return true }
    }
    return false
}

fn write_field(self: &CsvWriter, s: String) {
    if self.field_index > 0 {
        write_byte(self.w, self.options.delimiter)
    }
    if self.needs_quoting(s) {
        write_byte(self.w, self.options.quote)
        for (i in 0..s.len) {
            const c = s[i]
            if c == self.options.quote {
                write_byte(self.w, self.options.quote)
            }
            write_byte(self.w, c)
        }
        write_byte(self.w, self.options.quote)
    } else {
        write_str(self.w, s)
    }
    self.field_index = self.field_index + 1
}

// Encoder interface implementation

pub fn encode_null(self: &CsvWriter) usize {
    self.write_value("")
    return 0
}

pub fn encode_bool(self: &CsvWriter, v: bool) usize {
    if v { self.write_value("true") }
    else { self.write_value("false") }
    return 0
}

pub fn encode_int(self: &CsvWriter, v: i64, width: u8) usize {
    let buf = [0u8; 21]
    const len = format_i64(v, buf).unwrap()
    const view = .{ ptr = &buf[0], len = len } as String
    self.write_value(view)
    return 0
}

pub fn encode_uint(self: &CsvWriter, v: u64, width: u8) usize {
    let buf = [0u8; 21]
    const len = format_u64(v, buf).unwrap()
    const view = .{ ptr = &buf[0], len = len } as String
    self.write_value(view)
    return 0
}

pub fn encode_float(self: &CsvWriter, v: f64, width: u8) usize {
    let sb = string_builder(32)
    sb.append(v)
    self.write_value(sb.as_view())
    sb.deinit()
    return 0
}

pub fn encode_str(self: &CsvWriter, v: String) usize {
    self.write_value(v)
    return 0
}

pub fn encode_bytes(self: &CsvWriter, v: u8[]) usize {
    const view = .{ ptr = v.ptr, len = v.len } as String
    self.write_value(view)
    return 0
}

fn write_value(self: &CsvWriter, v: String) {
    if self.header_written == false {
        // First row: collect values, will emit after end_map
        let owned = from_view(v, null)
        self.first_row_values.push(owned)
    } else {
        self.write_field(v)
    }
}

pub fn begin_seq(self: &CsvWriter, len: usize) usize { return 0 }
pub fn end_seq(self: &CsvWriter) usize { return 0 }
pub fn begin_map(self: &CsvWriter, len: usize) usize {
    self.field_index = 0
    return 0
}

pub fn end_map(self: &CsvWriter) usize {
    if self.header_written == false {
        self.header_written = true
        // Write header row from collected keys
        for (i in 0..self.current_keys.len) {
            if i > 0 { write_byte(self.w, self.options.delimiter) }
            write_str(self.w, self.current_keys.as_slice()[i].as_view())
        }
        write_byte(self.w, 0x0A)
        // Write first data row from collected values
        for (i in 0..self.first_row_values.len) {
            if i > 0 { write_byte(self.w, self.options.delimiter) }
            const val = self.first_row_values.as_slice()[i].as_view()
            self.field_index = i
            self.write_field(val)
        }
        self.first_row_values.deinit()
        let empty_vals: List(OwnedString) = list(0)
        self.first_row_values = empty_vals
    }
    write_byte(self.w, 0x0A)
    self.row_count = self.row_count + 1
    self.field_index = 0
    return 0
}

pub fn key(self: &CsvWriter, name: String) usize {
    if self.header_written == false {
        let owned = from_view(name, null)
        self.current_keys.push(owned)
    }
    return 0
}

pub fn is_human_readable(self: &CsvWriter) bool { return true }

#implement(CsvWriter, Encoder)

pub fn deinit(self: &CsvWriter) {
    for (i in 0..self.current_keys.len) {
        self.current_keys.as_slice()[i].deinit()
    }
    self.current_keys.deinit()
}

// =============================================================================
// CsvTable construction and querying
// =============================================================================

pub fn csv_table(r: Reader, options: CsvOptions = csv_options()) Result(CsvTable, CsvError) {
    let reader = csv_reader(r, options)
    let table: CsvTable
    let rows: List(CsvRecord)
    table.rows = rows

    // Read all rows
    loop {
        let rec = reader.next_record()
        if rec.is_none() { break }
        table.rows.push(rec.value)
    }

    if reader.has_error() {
        reader.deinit()
        return Result.Err(reader.error.value)
    }

    // Transfer ownership: headers and arena move from reader to table
    table.headers = reader.headers
    table.arena = reader.arena

    // Don't deinit the arena — table owns it now.
    // Just clean up the reader's other resources.
    reader.field_buf.deinit()

    return Result.Ok(table)
}

pub fn select_rows(table: &CsvTable, start: usize, end: usize) CsvTable {
    let result: CsvTable
    result.arena = arena_allocator(&global_allocator)
    const arena_alloc = result.arena.allocator()

    // Copy headers
    let sel_headers: List(OwnedString) = list(table.headers.len)
    for (i in 0..table.headers.len) {
        const h = from_view(table.headers.as_slice()[i].as_view(), &arena_alloc)
        sel_headers.push(h)
    }
    result.headers = sel_headers

    // Copy selected rows
    const actual_end = if end > table.rows.len { table.rows.len } else { end }
    const actual_start = if start > actual_end { actual_end } else { start }
    let sel_rows: List(CsvRecord)
    result.rows = sel_rows

    for (i in actual_start..actual_end) {
        const src = &table.rows.as_slice()[i]
        let rec: CsvRecord
        let rec_fields: List(OwnedString) = list(src.fields.len)
        rec.fields = rec_fields
        rec.headers = &result.headers
        for (j in 0..src.fields.len) {
            const f = from_view(src.fields.as_slice()[j].as_view(), &arena_alloc)
            rec.fields.push(f)
        }
        result.rows.push(rec)
    }

    return result
}

pub fn select_columns(table: &CsvTable, names: String[]) CsvTable {
    let result: CsvTable
    result.arena = arena_allocator(&global_allocator)
    const arena_alloc = result.arena.allocator()

    // Find column indices
    let indices: List(usize)
    for (n in 0..names.len) {
        for (i in 0..table.headers.len) {
            if table.headers.as_slice()[i].as_view() == names[n] {
                indices.push(i)
                break
            }
        }
    }

    // Copy selected headers
    let col_headers: List(OwnedString) = list(indices.len)
    for (i in 0..indices.len) {
        const idx = indices.as_slice()[i]
        const h = from_view(table.headers.as_slice()[idx].as_view(), &arena_alloc)
        col_headers.push(h)
    }
    result.headers = col_headers

    // Copy rows with selected columns
    let col_rows: List(CsvRecord)
    result.rows = col_rows
    for (r in 0..table.rows.len) {
        const src = &table.rows.as_slice()[r]
        let rec: CsvRecord
        let rec_fields: List(OwnedString) = list(indices.len)
        rec.fields = rec_fields
        rec.headers = &result.headers
        for (j in 0..indices.len) {
            const idx = indices.as_slice()[j]
            if idx < src.fields.len {
                const f = from_view(src.fields.as_slice()[idx].as_view(), &arena_alloc)
                rec.fields.push(f)
            } else {
                const f = from_view("", &arena_alloc)
                rec.fields.push(f)
            }
        }
        result.rows.push(rec)
    }

    indices.deinit()
    return result
}

// =============================================================================
// Tests
// =============================================================================

test "parse simple CSV" {
    const input = "a\n1\n"
    let mr = mem_reader(input)
    let r = csv_reader(mr.reader())
    const rec = r.next_record()
    assert_true(rec.is_some(), "should have record")
    r.deinit()
}

test "parse CSV with quoted fields" {
    const input = "name,city\n\"Alice, Jr.\",\"New York\"\nBob,London\n"
    let mr = mem_reader(input)
    let r = csv_reader(mr.reader())
    const rec1 = r.next_record()
    assert_true(rec1.is_some(), "should have first record")
    const name1 = rec1.value.get("name")
    assert_true(name1.is_some(), "should have name field")
    r.deinit()
}

test "get by index" {
    const input = "a,b,c\n1,2,3\n"
    let mr = mem_reader(input)
    let r = csv_reader(mr.reader())
    const rec = r.next_record()
    assert_true(rec.is_some(), "should have record")
    assert_eq(rec.value.get(0usize).value, "1", "index 0")
    assert_eq(rec.value.get(1usize).value, "2", "index 1")
    assert_eq(rec.value.get(2usize).value, "3", "index 2")
    assert_true(rec.value.get(3usize).is_none(), "index 3 out of bounds")
    r.deinit()
}

test "CRLF line endings" {
    const input = "a,b\r\n1,2\r\n3,4\r\n"
    let mr = mem_reader(input)
    let r = csv_reader(mr.reader())
    const rec1 = r.next_record()
    assert_true(rec1.is_some(), "should have first record")
    assert_eq(rec1.value.get("a").value, "1", "first a")
    const rec2 = r.next_record()
    assert_true(rec2.is_some(), "should have second record")
    assert_eq(rec2.value.get("a").value, "3", "second a")
    r.deinit()
}

test "CR only line endings" {
    const input = "a,b\r1,2\r3,4\r"
    let mr = mem_reader(input)
    let r = csv_reader(mr.reader())
    const rec1 = r.next_record()
    assert_true(rec1.is_some(), "should have first record")
    assert_eq(rec1.value.get("a").value, "1", "first a")
    const rec2 = r.next_record()
    assert_true(rec2.is_some(), "should have second record")
    assert_eq(rec2.value.get("a").value, "3", "second a")
    r.deinit()
}

// TODO: csv_table, select_rows, select_columns, csv_writer tests disabled
// pending fix for List(CsvRecord) monomorphization crash
