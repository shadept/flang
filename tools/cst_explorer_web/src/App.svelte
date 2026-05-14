<script>
  import { onMount } from 'svelte'
  import DropZone from './lib/DropZone.svelte'
  import SourceView from './lib/SourceView.svelte'
  import TreeView from './lib/TreeView.svelte'
  import DiagnosticsList from './lib/DiagnosticsList.svelte'
  import { indexDump, findAtOffset, isToken } from './lib/dump.js'

  /** @type {ReturnType<typeof indexDump> | null} */
  let dump = $state(null)
  let error = $state('')
  /** [start, end] byte range currently highlighted, or null. */
  let highlight = $state(null)
  /** Set of node ids to focus / scroll into view in the tree. */
  let focusedNodeId = $state(null)
  /** Which tree to render in the right pane: 'cst' or 'ast'. */
  let pane = $state('cst')

  let activeTree = $derived(pane === 'ast' ? dump?.ast : dump?.tree)

  async function loadFile(file) {
    error = ''
    try {
      const text = await file.text()
      const raw = JSON.parse(text)
      dump = indexDump(raw)
      highlight = null
      pane = 'cst'
      focusedNodeId = dump.tree?.id ?? null
    } catch (e) {
      error = e?.message ?? String(e)
      dump = null
    }
  }

  function loadSample() {
    error = ''
    fetch('./sample.json')
      .then((r) => (r.ok ? r.json() : Promise.reject(`HTTP ${r.status}`)))
      .then((raw) => {
        dump = indexDump(raw)
        highlight = null
        pane = 'cst'
        focusedNodeId = dump.tree?.id ?? null
      })
      .catch((e) => { error = `couldn't load sample: ${e}` })
  }

  function selectPane(next) {
    if (pane === next) return
    pane = next
    // Read the new tree directly — `activeTree` ($derived) hasn't
    // re-evaluated yet inside this synchronous handler.
    const newTree = next === 'ast' ? dump?.ast : dump?.tree
    focusedNodeId = newTree?.id ?? null
    highlight = null
  }

  onMount(() => {
    // Allow `?sample=1` in the URL to auto-load the bundled fixture.
    const params = new URLSearchParams(location.search)
    if (params.has('sample')) loadSample()
  })

  function onSelectRange(range) {
    highlight = range
  }

  function onSelectNode(node) {
    if (!node) { highlight = null; focusedNodeId = null; return }
    if (isToken(node)) {
      highlight = [node.offset, node.end]
    } else {
      highlight = [node.start, node.end]
    }
    focusedNodeId = node.id ?? null
  }

  function onClickAtOffset(offset) {
    if (!activeTree) return
    const hit = findAtOffset(activeTree, offset)
    if (hit) onSelectNode(hit)
  }

  function clearDump() {
    dump = null
    highlight = null
    focusedNodeId = null
  }
</script>

<header>
  <div class="title">
    <strong>FLang Syntax Explorer</strong>
    <span class="dim">— drop a JSON dump produced by</span>
    <code class="dim">cst_explorer &lt;file&gt; --json &gt; out.json</code>
  </div>
  {#if dump}
    <div class="meta">
      <span class="dim">{dump.file}</span>
      <span class="dim">·</span>
      <span class="dim">{dump.tokens.length} tokens</span>
      <span class="dim">·</span>
      <span class="dim">{dump.nodeCount} nodes</span>
      {#if dump.diagnostics.length > 0}
        <span class="dim">·</span>
        <span class="err">{dump.diagnostics.length} diagnostic{dump.diagnostics.length === 1 ? '' : 's'}</span>
      {/if}
      <button onclick={clearDump}>clear</button>
    </div>
  {/if}
</header>

{#if !dump}
  <div class="empty">
    <DropZone onLoad={loadFile} />
    {#if error}
      <div class="error">⚠ {error}</div>
    {/if}
    <div class="hint">
      Or <button onclick={loadSample}>load the bundled sample</button>
      (a small <code>hello-world</code> dump).
    </div>
  </div>
{:else}
  <main>
    <section class="source">
      <h2>Source</h2>
      <SourceView
        source={dump.source}
        tokens={dump.tokens}
        diagnostics={dump.diagnostics}
        {highlight}
        onSelectRange={onSelectRange}
        onClickAtOffset={onClickAtOffset}
      />
    </section>
    <section class="tree">
      <div class="tree-header">
        <div class="pane-tabs" role="tablist">
          <button
            role="tab"
            aria-selected={pane === 'cst'}
            class:active={pane === 'cst'}
            onclick={() => selectPane('cst')}
          >CST <span class="count">{dump.nodeCount}</span></button>
          <button
            role="tab"
            aria-selected={pane === 'ast'}
            class:active={pane === 'ast'}
            disabled={!dump.ast}
            title={dump.ast ? '' : 'AST not present in this dump'}
            onclick={() => selectPane('ast')}
          >AST <span class="count">{dump.astNodeCount}</span></button>
        </div>
      </div>
      {#if activeTree}
        <!-- Remount on pane switch so per-node `open` state doesn't leak between trees. -->
        {#key pane}
          <TreeView
            tree={activeTree}
            tokens={dump.tokens}
            focusedId={focusedNodeId}
            onSelectNode={onSelectNode}
          />
        {/key}
      {:else}
        <div class="empty-pane">
          {pane === 'ast' ? 'AST not present in this dump.' : 'No tree.'}
        </div>
      {/if}
    </section>
  </main>
  {#if dump.diagnostics.length > 0}
    <aside class="diagnostics">
      <DiagnosticsList diagnostics={dump.diagnostics} onSelectRange={onSelectRange} />
    </aside>
  {/if}
{/if}

<style>
  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 10px 16px;
    border-bottom: 1px solid var(--border);
    background: var(--bg-elev);
    gap: 16px;
  }
  .title { font-size: 14px }
  .dim { color: var(--fg-dim) }
  .err { color: var(--err) }
  .meta { display: flex; align-items: center; gap: 10px; font-size: 12px }

  main {
    display: grid;
    grid-template-columns: minmax(0, 1fr) minmax(0, 1fr);
    height: calc(100vh - 50px);
  }
  section { display: flex; flex-direction: column; min-height: 0 }
  section + section { border-left: 1px solid var(--border) }
  h2 {
    margin: 0;
    padding: 6px 12px;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: var(--fg-dim);
    border-bottom: 1px solid var(--border);
    background: var(--bg-elev);
  }

  .tree-header {
    border-bottom: 1px solid var(--border);
    background: var(--bg-elev);
  }
  .pane-tabs {
    display: flex;
    gap: 0;
  }
  .pane-tabs button {
    background: transparent;
    border: none;
    border-right: 1px solid var(--border);
    color: var(--fg-dim);
    cursor: pointer;
    padding: 6px 14px;
    font: inherit;
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    border-bottom: 2px solid transparent;
    margin-bottom: -1px;
  }
  .pane-tabs button:hover:not(:disabled) { color: var(--fg) }
  .pane-tabs button.active {
    color: var(--accent);
    border-bottom-color: var(--accent);
    background: var(--bg);
  }
  .pane-tabs button:disabled {
    opacity: 0.4;
    cursor: not-allowed;
  }
  .pane-tabs .count {
    color: var(--fg-muted);
    margin-left: 6px;
    font-weight: 400;
  }
  .empty-pane {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--fg-dim);
    font-size: 12px;
    padding: 20px;
  }

  .empty {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    height: calc(100vh - 50px);
    gap: 14px;
    padding: 20px;
  }
  .error {
    color: var(--err);
    background: rgba(248, 81, 73, 0.12);
    padding: 8px 12px;
    border-radius: 6px;
    border: 1px solid rgba(248, 81, 73, 0.4);
    font-family: ui-monospace, monospace;
    font-size: 12px;
  }
  .hint { color: var(--fg-dim); font-size: 12px }

  .diagnostics {
    position: fixed;
    bottom: 0;
    left: 0;
    right: 0;
    max-height: 30vh;
    overflow: auto;
    background: var(--bg-elev);
    border-top: 1px solid var(--border);
  }
</style>
