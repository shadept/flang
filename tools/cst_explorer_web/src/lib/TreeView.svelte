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

  // Poll across ticks — deeply-nested rows mount one level per render
  // pass as `{#if open}` cascades, so the row may not exist on tick 1.
  $effect(() => {
    const id = focusedId
    if (!id || !scroller) return
    let cancelled = false
    const tryScroll = async () => {
      for (let attempt = 0; attempt < 8 && !cancelled; attempt++) {
        await tick()
        const row = scroller.querySelector(`[data-row-id="${cssEscape(id)}"]`)
        if (row) {
          row.scrollIntoView({ block: 'center', behavior: 'smooth' })
          return
        }
      }
    }
    tryScroll()
    return () => { cancelled = true }
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
