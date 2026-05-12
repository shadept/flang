<script>
  /** @type {{ diagnostics: Array<any>, onSelectRange: (r: [number, number]) => void }} */
  let { diagnostics, onSelectRange } = $props()

  let open = $state(true)
</script>

<div class="bar">
  <button onclick={() => (open = !open)}>
    {open ? '▾' : '▸'} {diagnostics.length} diagnostic{diagnostics.length === 1 ? '' : 's'}
  </button>
</div>

{#if open}
  <ul>
    {#each diagnostics as d}
      <li>
        <button class="diag-row" onclick={() => onSelectRange([d.start, d.end])}>
          <span class="code">[{d.code}]</span>
          <span class="msg">{d.message}</span>
          <span class="range">@{d.start}..{d.end}</span>
        </button>
      </li>
    {/each}
  </ul>
{/if}

<style>
  .bar {
    display: flex;
    align-items: center;
    padding: 6px 12px;
    border-bottom: 1px solid var(--border);
    font-size: 12px;
  }
  ul {
    margin: 0;
    padding: 6px 12px 12px;
    list-style: none;
    font-family: ui-monospace, monospace;
    font-size: 12px;
  }
  li {
    list-style: none;
  }
  .diag-row {
    width: 100%;
    text-align: left;
    background: transparent;
    border: none;
    color: inherit;
    font: inherit;
    padding: 4px 6px;
    cursor: pointer;
    border-radius: 4px;
  }
  .diag-row:hover { background: var(--bg-elev-2) }
  .code { color: var(--err); margin-right: 6px; font-weight: 600 }
  .msg { color: var(--fg) }
  .range { color: var(--fg-muted); margin-left: 8px }
</style>
