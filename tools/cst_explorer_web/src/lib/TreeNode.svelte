<script>
  import { untrack } from 'svelte'
  import Self from './TreeNode.svelte'
  import { tokenCategory } from './dump.js'

  /** @type {{
   *   node: any, depth: number, focusedId: string | null,
   *   onSelectNode: (n: any) => void
   * }} */
  let { node, depth, focusedId, onSelectNode } = $props()

  // `open` priority: autoOpen (focus on descendant) wins over userOpen,
  // which overrides the depth default. Derived rather than state-via-effect
  // so deep auto-expand cascades in one synchronous render pass — with the
  // effect form, each level had to mount before its own auto-expand ran.
  let userOpen = $state(/** @type {boolean | null} */ (null))
  let autoOpen = $derived(
    !!(focusedId && typeof focusedId === 'string' && focusedId.startsWith(node.id + '.'))
  )
  let defaultOpen = untrack(() => depth) < 3
  let open = $derived(autoOpen || (userOpen !== null ? userOpen : defaultOpen))
  let isFocused = $derived(focusedId === node.id)

  function toggle(e) {
    e.stopPropagation()
    userOpen = !open
  }
  function select(e) {
    e.stopPropagation()
    onSelectNode(node)
  }

  function previewToken(text) {
    if (text.length <= 28) return text
    return text.slice(0, 28) + '…'
  }

  // Children are heterogeneous: TreeNodes (with .kind + .children) and
  // tokens (with .offset + .text). Distinguish on `isToken === false`.
  function isToken(c) { return c && c.isToken !== false }
</script>

<div class="row" class:focused={isFocused} data-row-id={node.id}>
  <button class="caret" onclick={toggle} aria-label="toggle">
    {#if node.children.length === 0}
      <span class="leaf">·</span>
    {:else if open}▾{:else}▸{/if}
  </button>
  <button class="label" onclick={select}>
    {#if node.label}<span class="field">{node.label}:</span>{/if}
    <span class="kind">{node.kind}</span>
    <span class="range">[{node.start}..{node.end}]</span>
    {#if node.scalars}
      {#each node.scalars as s}
        <span class="scalar"><span class="scalar-key">{s.key}</span>=<span class="scalar-val">{s.value}</span></span>
      {/each}
    {/if}
  </button>
</div>

{#if open}
  <div class="children" style="--depth: {depth + 1}">
    {#each node.children as child}
      {#if isToken(child)}
        <div class="row tok" class:focused={focusedId === child.id} data-row-id={child.id}>
          <span class="caret"><span class="leaf">·</span></span>
          <button class="label token" onclick={() => onSelectNode(child)}>
            <span class={`tok-kind ${tokenCategory(child.kind)}`}>{child.kind}</span>
            <span class="token-text mono">{previewToken(child.text)}</span>
            <span class="range">@{child.offset}</span>
          </button>
        </div>
      {:else}
        <Self node={child} depth={depth + 1} {focusedId} {onSelectNode} />
      {/if}
    {/each}
  </div>
{/if}

<style>
  .row {
    display: flex;
    align-items: center;
    gap: 2px;
    padding-left: calc(var(--depth, 0) * 14px);
    border-radius: 4px;
  }
  .row.focused {
    background: var(--accent-soft);
    box-shadow: inset 2px 0 0 var(--accent);
  }
  .caret {
    flex: 0 0 18px;
    width: 18px;
    height: 18px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    background: transparent;
    border: none;
    color: var(--fg-dim);
    cursor: pointer;
    padding: 0;
    /* Match parent font-size so glyph metrics line up across all rows
       (expandable nodes had 11px while token leaves inherited 12.5px,
       which shifted the caret column by ~1px at higher depths). */
    font-size: inherit;
    line-height: 1;
  }
  .caret:hover { color: var(--fg) }
  .leaf { color: var(--fg-muted); opacity: 0.5; line-height: 1 }
  .label {
    background: transparent;
    border: none;
    color: inherit;
    cursor: pointer;
    padding: 1px 6px;
    border-radius: 4px;
    font: inherit;
    text-align: left;
  }
  .label:hover { background: var(--bg-elev) }
  .kind { color: var(--accent); font-weight: 600 }
  .field { color: var(--fg-dim); font-weight: 500; margin-right: 4px }
  .range { color: var(--fg-muted); margin-left: 6px; font-size: 11px }
  .scalar { color: var(--fg-dim); margin-left: 8px; font-size: 11px }
  .scalar-key { color: var(--fg-muted) }
  .scalar-val { color: var(--str) }
  .children { display: contents }

  .row.tok { opacity: 0.92 }
  .tok-kind.kw { color: var(--kw) }
  .tok-kind.str { color: var(--str) }
  .tok-kind.num { color: var(--num) }
  .tok-kind.id { color: var(--accent) }
  .tok-kind.punct { color: var(--fg-dim) }
  .token-text { margin-left: 8px; color: var(--fg); opacity: 0.85 }
</style>
