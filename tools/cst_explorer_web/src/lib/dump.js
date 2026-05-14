// Normalize the raw `cst_explorer --json` dump. Both `tree` (CST) and
// `ast` are mapped to the same tree node shape so one renderer handles
// either pane. Every node gets a stable `id`; CST tokens are resolved
// from indexes into objects.

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
        // Same token instance appears in both `tokens[]` and the tree;
        // pinning ids on it makes both contexts share row identity.
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

  // AST is optional — older dumps may only carry the CST.
  const ast = raw.ast ? indexAst(raw.ast, 'a') : null
  const astNodeCount = ast ? countNodes(ast) : 0

  const diagnostics = (raw.diagnostics ?? []).map((d) => ({
    ...d,
    end: d.start + (d.length ?? 0),
  }))

  return {
    file: raw.file ?? '(unknown)',
    source: raw.source,
    tokens,
    tree,
    ast,
    diagnostics,
    nodeCount,
    astNodeCount,
  }
}

// Map a raw AST node to the same shape `indexNode` produces for CST,
// plus `scalars` for primitive fields and `label` on labelled children.
// Arrays expand inline (each element becomes a labelled child); null
// fields are skipped.
function indexAst(node, path) {
  if (!node || typeof node !== 'object') return null
  const id = path
  const [start, length] = Array.isArray(node.span) ? node.span : [0, 0]
  const scalars = []
  const children = []

  for (const [key, value] of Object.entries(node)) {
    if (key === 'kind' || key === 'span') continue
    appendAstField(scalars, children, key, value, id)
  }

  return {
    id,
    isToken: false,
    isAst: true,
    kind: node.kind ?? '?',
    start,
    end: start + length,
    scalars,
    children,
  }
}

function appendAstField(scalars, children, key, value, parentId) {
  if (value === null || value === undefined) return
  if (typeof value === 'string' || typeof value === 'boolean' || typeof value === 'number') {
    scalars.push({ key, value: String(value) })
    return
  }
  if (Array.isArray(value)) {
    if (value.length === 0) {
      // Surface empty arrays so absence is visible.
      scalars.push({ key, value: '[]' })
      return
    }
    value.forEach((item, i) => {
      if (item === null || typeof item !== 'object') {
        scalars.push({ key: `${key}[${i}]`, value: String(item) })
        return
      }
      const childId = `${parentId}.${key}[${i}]`
      const childNode = indexAst(item, childId)
      if (childNode) {
        childNode.label = `${key}[${i}]`
        children.push(childNode)
      }
    })
    return
  }
  // Nested AST node.
  const childId = `${parentId}.${key}`
  const childNode = indexAst(value, childId)
  if (childNode) {
    childNode.label = key
    children.push(childNode)
  }
}

function countNodes(node) {
  if (!node) return 0
  let n = 1
  for (const c of node.children ?? []) n += countNodes(c)
  return n
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
