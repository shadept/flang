<script>
  import { tick } from 'svelte'
  import { tokenCategory } from './dump.js'

  /** @type {{
   *   source: string,
   *   tokens: Array<any>,
   *   diagnostics: Array<any>,
   *   highlight: [number, number] | null,
   *   onSelectRange: (r: [number, number] | null) => void,
   *   onClickAtOffset: (offset: number) => void
   * }} */
  let { source, tokens, diagnostics, highlight, onSelectRange, onClickAtOffset } = $props()

  let scroller
  // Set by hover/click in this pane so the highlight effect below
  // skips its own scroll — otherwise hovering inside the source pane
  // would yank scroll position around.
  let suppressNextScroll = false

  // Build the rendered token list. We walk every token and emit
  // leading trivia + text + trailing trivia in order; this exactly
  // mirrors the round-trip invariant the formatter relies on.
  let parts = $derived(buildParts(source, tokens))

  // Diagnostic-range index — quick lookup for highlighting error spans.
  let diagRanges = $derived(diagnostics.map((d) => [d.start, d.end]))

  function buildParts(source, tokens) {
    const out = []
    for (const t of tokens) {
      for (const tr of t.leading ?? []) {
        out.push({ kind: 'trivia', triviaKind: tr.kind, text: tr.text })
      }
      out.push({
        kind: 'token',
        tokenKind: t.kind,
        category: tokenCategory(t.kind),
        text: t.text,
        start: t.offset,
        end: t.end,
        index: t.index,
      })
      for (const tr of t.trailing ?? []) {
        out.push({ kind: 'trivia', triviaKind: tr.kind, text: tr.text })
      }
    }
    return out
  }

  function inRange(start, end) {
    if (!highlight) return false
    return start >= highlight[0] && end <= highlight[1]
  }

  function intersectsAnyDiag(start, end) {
    for (const [ds, de] of diagRanges) {
      if (start < de && end > ds) return true
    }
    return false
  }

  function hover(part) {
    if (part.kind === 'token') {
      suppressNextScroll = true
      onSelectRange([part.start, part.end])
    }
  }
  function click(part) {
    if (part.kind === 'token') {
      suppressNextScroll = true
      onClickAtOffset(part.start)
    }
  }
  function leave() { /* keep last highlight until a tree click clears it */ }

  // When the highlighted range changes from an external source (a tree
  // click), scroll the first span covering that range into view. We
  // skip the scroll when the change came from this pane.
  $effect(() => {
    const hl = highlight
    if (!hl || !scroller) return
    if (suppressNextScroll) {
      suppressNextScroll = false
      return
    }
    tick().then(() => {
      const span = scroller.querySelector(
        `span.tok[data-start="${hl[0]}"]`,
      )
      if (span) span.scrollIntoView({ block: 'center', behavior: 'smooth' })
    })
  })
</script>

<!--
  Whitespace inside <pre> is significant, so the template is intentionally
  glued together with no newlines / indentation between tags. Any
  pretty-printing here would leak literal blank lines into the source view.
-->
<pre class="source mono" bind:this={scroller} onmouseleave={leave}>{#each parts as p}{#if p.kind === 'trivia'}<span class={p.triviaKind === 'LineComment' ? 'comment' : 'ws'}>{p.text}</span>{:else}<span role="presentation" class="tok {p.category}" class:hl={inRange(p.start, p.end)} class:diag={intersectsAnyDiag(p.start, p.end)} data-start={p.start} data-end={p.end} title={`${p.tokenKind} @${p.start}..${p.end}`} onmouseenter={() => hover(p)} onclick={() => click(p)}>{p.text}</span>{/if}{/each}</pre>

<style>
  .source {
    flex: 1;
    margin: 0;
    padding: 12px 16px;
    overflow: auto;
    background: var(--bg);
    color: var(--fg);
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.5;
    font-size: 12.5px;
  }
  .tok { border-radius: 2px; cursor: pointer }
  .tok:hover { background: var(--bg-elev) }
  .tok.kw { color: var(--kw) }
  .tok.str { color: var(--str) }
  .tok.num { color: var(--num) }
  .tok.id { color: var(--fg) }
  .tok.punct { color: var(--fg-dim) }
  .tok.hl { background: var(--hl); box-shadow: inset 0 0 0 1px var(--hl-strong) }
  .tok.diag { text-decoration: underline wavy var(--err); text-underline-offset: 3px }
  .comment { color: var(--comment); font-style: italic }
  .ws { white-space: pre }
</style>
