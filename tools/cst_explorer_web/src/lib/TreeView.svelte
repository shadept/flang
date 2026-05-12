<script>
  import { tick } from 'svelte'
  import TreeNode from './TreeNode.svelte'

  /** @type {{
   *   tree: any,
   *   tokens: Array<any>,
   *   focusedId: string | null,
   *   onSelectNode: (n: any) => void
   * }} */
  let { tree, tokens, focusedId, onSelectNode } = $props()

  let scroller

  // Scroll the focused row into view after Svelte flushes the
  // ancestor-open effects (which may add new rows to the DOM). We use
  // a tick so collapsed ancestors have a chance to render their
  // children before we measure.
  $effect(() => {
    const id = focusedId
    if (!id || !scroller) return
    tick().then(() => {
      const row = scroller.querySelector(`[data-row-id="${cssEscape(id)}"]`)
      if (row) row.scrollIntoView({ block: 'center', behavior: 'smooth' })
    })
  })

  function cssEscape(s) {
    // Ids contain dots — CSS.escape handles them across browsers.
    return typeof CSS !== 'undefined' && CSS.escape ? CSS.escape(s) : s.replace(/\./g, '\\.')
  }
</script>

<div class="tree mono" bind:this={scroller}>
  <TreeNode node={tree} depth={0} {focusedId} {onSelectNode} />
</div>

<style>
  .tree {
    flex: 1;
    overflow: auto;
    padding: 6px 4px 60px;
    background: var(--bg);
    font-size: 12.5px;
    line-height: 1.5;
  }
</style>
