// Normalize the raw JSON produced by `flang cst --json` into a shape
// the UI can lean on directly: every node gets a stable `id`, token
// references are resolved into objects, and child arrays are
// flattened so a renderer can iterate without re-dispatching.

/**
 * @typedef {{ kind: string, text: string, offset: number, line: number,
 *   leading: Array<{kind: string, text: string}>,
 *   trailing: Array<{kind: string, text: string}>,
 *   end: number, index: number }} Token
 *
 * @typedef {{ id: string, isToken: false, kind: string, start: number,
 *   end: number, children: Array<TreeNode | Token> }} TreeNode
 *
 * @typedef {{ code: string, message: string, start: number,
 *   length: number, end: number }} Diagnostic
 */

export function indexDump(raw) {
  if (!raw || typeof raw !== 'object') throw new Error('not a JSON object')
  if (typeof raw.source !== 'string') throw new Error('missing `source` string')
  if (!Array.isArray(raw.tokens)) throw new Error('missing `tokens` array')
  if (!raw.tree) throw new Error('missing `tree`')

  const tokens = raw.tokens.map((t, i) => ({
    ...t,
    index: i,
    end: t.offset + (t.text?.length ?? 0),
  }))

  let nodeCount = 0
  /** @returns {TreeNode} */
  function indexNode(node, path) {
    nodeCount += 1
    const id = path
    const children = (node.children ?? []).map((child, i) => {
      const childId = `${id}.${i}`
      if (child.token !== undefined) {
        const tok = tokens[child.token]
        if (!tok) throw new Error(`token index ${child.token} out of range`)
        // Stamp the token with its position in the tree. Tokens are
        // shared by reference across the dump (the same token appears
        // once in the flat `tokens[]` array AND as a leaf in `tree`),
        // so the id pinned here works in both contexts.
        tok.id = childId
        tok.parentId = id
        return tok
      }
      if (child.node) return indexNode(child.node, childId)
      throw new Error(`unknown child shape at ${path}.${i}`)
    })
    return {
      id,
      isToken: false,
      kind: node.kind,
      start: node.start,
      end: node.end,
      children,
    }
  }

  const tree = indexNode(raw.tree, 'r')

  const diagnostics = (raw.diagnostics ?? []).map((d) => ({
    ...d,
    end: d.start + (d.length ?? 0),
  }))

  return {
    file: raw.file ?? '(unknown)',
    source: raw.source,
    tokens,
    tree,
    diagnostics,
    nodeCount,
  }
}

export function isToken(child) {
  return child && child.isToken !== false && typeof child.offset === 'number'
}

/**
 * Descend the tree to find the leaf (token) at `offset`, returning the
 * deepest enclosing entity. Returns either a token (with `offset`/`end`)
 * or the smallest CST node whose range contains the offset when no token
 * matches exactly (which happens inside trivia between tokens).
 */
export function findAtOffset(tree, offset) {
  let best = tree
  let cursor = tree
  while (cursor && !isToken(cursor)) {
    const next = cursor.children.find((c) => {
      if (isToken(c)) return c.offset <= offset && offset < c.end
      return c.start <= offset && offset < c.end
    })
    if (!next) break
    best = next
    cursor = next
  }
  return best
}

/** Heuristic syntax category for source coloring. */
export function tokenCategory(kind) {
  if (KEYWORDS.has(kind)) return 'kw'
  if (kind === 'StringLiteral' || kind === 'CharLiteral' || kind === 'ByteLiteral'
      || kind === 'InterpStringStart' || kind === 'InterpStringEnd'
      || kind === 'InterpSegment') return 'str'
  if (kind === 'Integer' || kind === 'Float') return 'num'
  if (kind === 'Identifier') return 'id'
  return 'punct'
}

const KEYWORDS = new Set([
  'Pub', 'Fn', 'Return', 'Let', 'Const', 'If', 'Else', 'For', 'Loop',
  'While', 'In', 'Break', 'Continue', 'Defer', 'Import', 'Struct',
  'Enum', 'Match', 'As', 'Test', 'Type', 'And', 'Or', 'True', 'False', 'Null',
])
