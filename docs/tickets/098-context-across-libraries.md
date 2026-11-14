---
type: compiler
created: 2026-10-25
linear: SH-18
relates: [RFC-038, RFC-041]
---

# RFC-098: Context across separately compiled libraries

## Summary

The runtime context (RFC-038) is one flat struct whose layout is fixed per program: every
`context` field of every module, ordered by module FQN, read at a fixed offset. That holds while
the whole program is compiled at once. A library compiled on its own cannot know the offsets of
fields declared by the program that links it, nor they its.

This RFC records the layout that lifts the restriction when separate compilation arrives: a core
block the stdlib fixes, plus one tail per library that declares context fields. Whole-program
builds keep the flat struct.

## Design

- **Core.** The stdlib's fields (`allocator`, `temp_allocator`, the logger) sit in a block at
  offsets the stdlib fixes, so every library reads them with one load, as today.
- **Tails.** A library that declares context fields owns a block of them, laid out by the library
  alone. The context holds a linked list of tails, each entry naming its library by a key unique
  at link time (the address of a static the library owns) and pointing at the block.
- **Read.** A core field is one load. A library field walks the tail list to the library's key,
  then loads at the field's offset in that block.
- **Rebind.** Rebinding a core field copies the core block, as today. Rebinding a library field
  copies that library's block with the field replaced, and pushes a tail entry that shadows the
  library's earlier one for the body. Other tails are shared with the parent.
- **Static libraries.** A library compiled with the program gains nothing from a tail: its fields
  stay in the flat struct. Tails are for libraries compiled separately.

## Open questions

- Key lookup: a walk over the tails, or a slot index the loader assigns per library?
- A detached task (RFC-005) snapshots its context: does the snapshot copy every tail's block, or
  share the blocks it cannot outlive?
- Which fields belong to the core, and how the core grows without breaking libraries built
  against an older one.
