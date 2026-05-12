<script>
  /** @type {{ onLoad: (file: File) => void }} */
  let { onLoad } = $props()

  let dragOver = $state(false)
  let inputEl

  function onDrop(e) {
    e.preventDefault()
    dragOver = false
    const file = e.dataTransfer?.files?.[0]
    if (file) onLoad(file)
  }

  function onPick(e) {
    const file = e.target.files?.[0]
    if (file) onLoad(file)
  }
</script>

<div
  class="drop"
  class:over={dragOver}
  ondragover={(e) => { e.preventDefault(); dragOver = true }}
  ondragleave={() => (dragOver = false)}
  ondrop={onDrop}
  onclick={() => inputEl?.click()}
  onkeydown={(e) => { if (e.key === 'Enter' || e.key === ' ') inputEl?.click() }}
  role="button"
  tabindex="0"
>
  <input type="file" accept=".json,application/json" bind:this={inputEl} onchange={onPick} hidden />
  <div class="icon">📂</div>
  <div>Drop a <code>flang cst --json</code> output here</div>
  <div class="sub">or click to choose a file</div>
</div>

<style>
  .drop {
    width: min(520px, 90%);
    padding: 36px 24px;
    border: 2px dashed var(--border);
    border-radius: 10px;
    text-align: center;
    cursor: pointer;
    background: var(--bg-elev);
    transition: border-color 120ms, background 120ms;
  }
  .drop:hover, .drop.over {
    border-color: var(--accent);
    background: var(--bg-elev-2);
  }
  .icon { font-size: 32px; margin-bottom: 8px }
  .sub { color: var(--fg-dim); font-size: 12px; margin-top: 6px }
  code { color: var(--accent) }
</style>
