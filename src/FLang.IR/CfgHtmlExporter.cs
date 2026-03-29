using System.Text;
using FLang.IR.Instructions;

namespace FLang.IR;

/// <summary>
/// Exports the control flow graph of an IrModule as a self-contained HTML file
/// using Mermaid.js (loaded from CDN — zero local dependencies).
/// </summary>
public static class CfgHtmlExporter
{
    public static string Export(IrModule module, string? startFunction = "main")
    {
        var sb = new StringBuilder();

        var functions = new List<IrFunction>();
        var mainFn = module.Functions.FirstOrDefault(f => f.Name == startFunction);
        if (mainFn != null)
            functions.Add(mainFn);
        foreach (var fn in module.Functions)
            if (fn != mainFn && fn.BasicBlocks.Count > 0)
                functions.Add(fn);

        sb.Append(HtmlHead);

        // Sidebar
        sb.AppendLine("<div id=\"sidebar\">");
        sb.AppendLine("  <div class=\"sidebar-header\">CFG Explorer</div>");
        sb.AppendLine("  <input type=\"text\" id=\"search\" placeholder=\"Filter functions...\" autocomplete=\"off\">");
        sb.AppendLine("  <div id=\"fn-list\">");
        for (int i = 0; i < functions.Count; i++)
        {
            var fn = functions[i];
            var cls = i == 0 ? " class=\"active\"" : "";
            var blocks = fn.BasicBlocks.Count;
            sb.AppendLine($"    <button{cls} data-fn=\"{EscapeAttr(fn.Name)}\" data-name=\"{EscapeAttr(fn.Name.ToLowerInvariant())}\">");
            sb.AppendLine($"      <span class=\"fn-name\">{EscapeHtml(fn.Name)}</span>");
            sb.AppendLine($"      <span class=\"fn-meta\">{blocks} block{(blocks != 1 ? "s" : "")}</span>");
            sb.AppendLine($"    </button>");
        }
        sb.AppendLine("  </div>");
        sb.AppendLine("</div>");

        // Main content
        sb.AppendLine("<div id=\"main\">");
        sb.AppendLine("  <div id=\"toolbar\">");
        sb.AppendLine("    <button onclick=\"zoomIn()\" title=\"Zoom in\">+</button>");
        sb.AppendLine("    <button onclick=\"zoomOut()\" title=\"Zoom out\">&minus;</button>");
        sb.AppendLine("    <button onclick=\"resetView()\" title=\"Reset view\">Reset</button>");
        sb.AppendLine("    <span id=\"zoom-level\">100%</span>");
        sb.AppendLine("  </div>");

        for (int i = 0; i < functions.Count; i++)
        {
            var fn = functions[i];
            var activeClass = i == 0 ? " active" : "";
            sb.AppendLine($"  <div class=\"fn-graph{activeClass}\" id=\"fn-{EscapeAttr(fn.Name)}\">");
            sb.AppendLine($"    <div class=\"graph-viewport\">");
            sb.AppendLine($"      <div class=\"graph-canvas\">");
            sb.AppendLine($"        <pre class=\"mermaid\">");
            sb.Append(BuildMermaidGraph(fn));
            sb.AppendLine("        </pre>");
            sb.AppendLine($"      </div>");
            sb.AppendLine($"    </div>");
            sb.AppendLine($"  </div>");
        }
        sb.AppendLine("</div>");

        sb.Append(Script());
        sb.AppendLine("</body></html>");
        return sb.ToString();
    }

    // =========================================================================
    // Mermaid graph generation
    // =========================================================================

    private static string BuildMermaidGraph(IrFunction fn)
    {
        var sb = new StringBuilder();
        sb.AppendLine("flowchart TD");

        if (fn.BasicBlocks.Count == 0)
        {
            sb.AppendLine("    empty[\"(no blocks)\"]");
            return sb.ToString();
        }

        var blockIds = new Dictionary<BasicBlock, string>();
        for (int i = 0; i < fn.BasicBlocks.Count; i++)
            blockIds[fn.BasicBlocks[i]] = $"B{i}";

        foreach (var block in fn.BasicBlocks)
        {
            var id = blockIds[block];
            var body = BuildBlockBody(block);
            sb.AppendLine($"    {id}[\"`{body}`\"]");
        }

        foreach (var block in fn.BasicBlocks)
        {
            var fromId = blockIds[block];
            var terminator = block.Instructions.Count > 0 ? block.Instructions[^1] : null;

            if (terminator is BranchInstruction br)
            {
                if (blockIds.TryGetValue(br.TrueBlock, out var trueId))
                    sb.AppendLine($"    {fromId} -->|T| {trueId}");
                if (blockIds.TryGetValue(br.FalseBlock, out var falseId))
                    sb.AppendLine($"    {fromId} -.->|F| {falseId}");
            }
            else if (terminator is JumpInstruction jmp)
            {
                if (blockIds.TryGetValue(jmp.TargetBlock, out var targetId))
                    sb.AppendLine($"    {fromId} --> {targetId}");
            }
        }

        sb.AppendLine($"    style B0 fill:#1f6feb,color:#fff");
        return sb.ToString();
    }

    private static string BuildBlockBody(BasicBlock block)
    {
        var sb = new StringBuilder();
        sb.Append($"**{Esc(block.Label)}**");

        // Show ALL instructions
        foreach (var inst in block.Instructions)
        {
            sb.Append('\n');
            sb.Append(SummarizeInstruction(inst));
        }

        return sb.ToString();
    }

    private static string SummarizeInstruction(Instruction inst)
    {
        return inst switch
        {
            AllocaInstruction a => $"{VN(a.Result)} = alloca {a.SizeInBytes}B",
            LoadInstruction l => $"{VN(l.Result)} = load {VN(l.Pointer)}",
            StorePointerInstruction s => $"store {VN(s.Value)}, {VN(s.Pointer)}",
            BinaryInstruction b => $"{VN(b.Result)} = {b.Operation} {VN(b.Left)}, {VN(b.Right)}",
            UnaryInstruction u => $"{VN(u.Result)} = {u.Operation} {VN(u.Operand)}",
            CallInstruction c => $"{VN(c.Result)} = call {Esc(c.FunctionName)}",
            IndirectCallInstruction ic => $"{VN(ic.Result)} = call.indirect",
            CastInstruction c => $"{VN(c.Result)} = cast {VN(c.Source)}",
            GetElementPtrInstruction g => $"{VN(g.Result)} = gep {VN(g.BasePointer)}",
            AddressOfInstruction a => $"{VN(a.Result)} = addr {Esc(a.VariableName)}",
            ReturnInstruction r => $"ret {VN(r.Value)}",
            JumpInstruction j => $"jmp {Esc(j.TargetBlock.Label)}",
            BranchInstruction br => $"br {VN(br.Condition)}",
            CopyFromOffsetInstruction cf => $"{VN(cf.Result)} = copy_from",
            CopyToOffsetInstruction => "copy_to",
            CopyInstruction cp => $"copy {VN(cp.SrcPtr)} to {VN(cp.DstPtr)}",
            _ => inst.GetType().Name
        };
    }

    private static string VN(Value v) => Esc(v switch
    {
        LocalValue l => l.Name,
        IntConstantValue i => i.IntValue.ToString(),
        FloatConstantValue f => f.FloatValue.ToString("G"),
        GlobalValue g => $"@{g.Name}",
        _ => "?"
    });

    private static string Esc(string s) => s
        .Replace("#", "﹟")
        .Replace("`", "'")
        .Replace("\"", "'");

    private static string EscapeHtml(string s) =>
        s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    private static string EscapeAttr(string s) =>
        s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")
         .Replace("\"", "&quot;").Replace("'", "&#39;");

    // =========================================================================
    // HTML
    // =========================================================================

    private const string HtmlHead = @"<!DOCTYPE html>
<html lang=""en""><head><meta charset=""utf-8"">
<title>FLang CFG</title>
<style>
  *{margin:0;padding:0;box-sizing:border-box}
  body{font-family:system-ui,-apple-system,sans-serif;background:#0d1117;color:#c9d1d9;overflow:hidden;height:100vh}
  #sidebar{position:fixed;top:0;left:0;width:260px;height:100vh;display:flex;flex-direction:column;
    background:#161b22;border-right:1px solid #30363d;z-index:10}
  .sidebar-header{padding:16px 16px 8px;font-size:13px;font-weight:600;color:#8b949e;
    text-transform:uppercase;letter-spacing:.5px}
  #search{margin:4px 12px 8px;padding:6px 10px;background:#0d1117;border:1px solid #30363d;
    border-radius:6px;color:#c9d1d9;font-size:13px;outline:none}
  #search:focus{border-color:#1f6feb}
  #fn-list{flex:1;overflow-y:auto;padding:0 8px 12px}
  #fn-list button{display:flex;flex-direction:column;width:100%;text-align:left;background:none;border:none;
    color:#c9d1d9;padding:6px 10px;font-size:13px;cursor:pointer;border-radius:6px;margin-bottom:1px}
  #fn-list button:hover{background:#21262d}
  #fn-list button.active{background:#1f6feb;color:#fff}
  #fn-list button.hidden{display:none}
  .fn-name{font-family:ui-monospace,monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .fn-meta{font-size:11px;color:#8b949e;margin-top:1px}
  #fn-list button.active .fn-meta{color:rgba(255,255,255,.7)}
  #main{position:fixed;top:0;left:260px;right:0;bottom:0;overflow:hidden}
  #toolbar{position:absolute;top:12px;right:16px;z-index:5;display:flex;align-items:center;gap:6px;
    background:#161b22;border:1px solid #30363d;border-radius:8px;padding:4px 8px}
  #toolbar button{background:none;border:1px solid #30363d;color:#c9d1d9;width:28px;height:28px;
    border-radius:6px;cursor:pointer;font-size:16px;display:flex;align-items:center;justify-content:center}
  #toolbar button:hover{background:#21262d}
  #zoom-level{font-size:12px;color:#8b949e;min-width:40px;text-align:center}
  .fn-graph{display:none;width:100%;height:100%}
  .fn-graph.active{display:block}
  .graph-viewport{width:100%;height:100%;overflow:auto}
  .graph-canvas{padding:24px}
  .graph-canvas svg{display:block}
  .render-error{padding:24px;color:#f85149;font-family:ui-monospace,monospace;font-size:13px;
    white-space:pre-wrap;background:#1c1214;border:1px solid #f8514930;border-radius:8px;margin:24px}
  #hints{position:fixed;bottom:12px;left:272px;font-size:11px;color:#484f58;z-index:5}
  kbd{background:#21262d;border:1px solid #30363d;border-radius:3px;padding:1px 5px;font-size:10px;font-family:inherit}
</style>
</head><body>
";

    // =========================================================================
    // JS
    // =========================================================================

    private static string Script()
    {
        return @"<div id=""hints""><kbd>Scroll</kbd> pan &nbsp; <kbd>Pinch</kbd> zoom &nbsp; <kbd>R</kbd> reset &nbsp; <kbd>+</kbd><kbd>&minus;</kbd> zoom &nbsp; <kbd>&#8593;&#8595;</kbd> prev/next fn &nbsp; <kbd>/</kbd> search</div>
<script type=""module"">
import mermaid from 'https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs';
mermaid.initialize({startOnLoad:false, theme:'dark', flowchart:{curve:'basis'}, securityLevel:'loose'});

// 1. Render all mermaid graphs
const allPres = [...document.querySelectorAll('.mermaid')];
await Promise.all(allPres.map(async (el, i) => {
  const src = el.textContent;
  try {
    const {svg} = await mermaid.render('g'+i, src);
    el.innerHTML = svg;
  } catch(e) {
    el.outerHTML = '<div class=""render-error"">Mermaid render error:\n' +
      e.message.replace(/</g,'&lt;') + '\n\nSource:\n' + src.replace(/</g,'&lt;') + '</div>';
  }
}));

// 2. For each rendered SVG, set up viewBox so we can scale it via width.
//    Compute a default width so the widest node is ~33% of the viewport.
const mainEl = document.getElementById('main');
const vpW = mainEl.clientWidth - 48; // minus padding

// Per-panel state: the SVG width in pixels when at ""100%""
const baseWidths = new Map();

document.querySelectorAll('.fn-graph').forEach(panel => {
  const svg = panel.querySelector('svg');
  if (!svg) return;

  // Read intrinsic size and ensure viewBox is set
  const natW = parseFloat(svg.getAttribute('width')) || svg.clientWidth || 400;
  const natH = parseFloat(svg.getAttribute('height')) || svg.clientHeight || 300;
  if (!svg.getAttribute('viewBox'))
    svg.setAttribute('viewBox', `0 0 ${natW} ${natH}`);
  svg.removeAttribute('width');
  svg.removeAttribute('height');
  svg.style.height = 'auto';

  // Find the widest node (any .node group)
  let maxNodeW = 0;
  svg.querySelectorAll('.node').forEach(n => {
    const w = n.getBBox?.()?.width || 0;
    if (w > maxNodeW) maxNodeW = w;
  });

  // At svg.style.width = X, the widest node renders at (maxNodeW / natW) * X pixels.
  // We want that to be ~33% of vpW:
  //   (maxNodeW / natW) * baseW = vpW * 0.33
  //   baseW = (vpW * 0.33 * natW) / maxNodeW
  // Clamp: at least 400px, at most vpW (fit to viewport).
  let baseW = vpW;
  if (maxNodeW > 0) {
    baseW = (vpW * 0.33 * natW) / maxNodeW;
    baseW = Math.max(400, Math.min(vpW, baseW));
  }

  baseWidths.set(panel, baseW);
  svg.style.width = baseW + 'px';
});

// 3. Zoom: multiplier on top of the per-panel baseWidth. 1 = default view.
let zoom = 1;
const MIN_ZOOM = 0.25, MAX_ZOOM = 5;

function activePanel()    { return document.querySelector('.fn-graph.active'); }
function activeSvg()      { const g = activePanel(); return g ? g.querySelector('svg') : null; }
function activeViewport() { const g = activePanel(); return g ? g.querySelector('.graph-viewport') : null; }

function applyZoom() {
  const svg = activeSvg(); if (!svg) return;
  const base = baseWidths.get(activePanel()) || vpW;
  svg.style.width = (base * zoom) + 'px';
  document.getElementById('zoom-level').textContent = Math.round(zoom * 100) + '%';
}

function resetView() {
  zoom = 1;
  applyZoom();
  const vp = activeViewport(); if (vp) { vp.scrollTop = 0; vp.scrollLeft = 0; }
}

window.zoomIn  = () => { zoom = Math.min(MAX_ZOOM, zoom * 1.25); applyZoom(); };
window.zoomOut = () => { zoom = Math.max(MIN_ZOOM, zoom / 1.25); applyZoom(); };
window.resetView = resetView;

// Pinch-to-zoom only (Ctrl+wheel). Normal scroll pans via overflow:auto.
mainEl.addEventListener('wheel', e => {
  if (!e.ctrlKey) return;
  e.preventDefault();
  const d = e.deltaY > 0 ? 1/1.1 : 1.1;
  zoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom * d));
  applyZoom();
}, {passive:false});

// Sidebar: switch function, reset zoom & scroll
function show(name, btn) {
  document.querySelectorAll('.fn-graph').forEach(e => e.classList.remove('active'));
  document.querySelectorAll('#fn-list button').forEach(b => b.classList.remove('active'));
  const el = document.getElementById('fn-' + CSS.escape(name));
  if (el) el.classList.add('active');
  if (btn) btn.classList.add('active');
  resetView();
}
document.querySelectorAll('#fn-list button').forEach(btn => {
  btn.addEventListener('click', () => show(btn.dataset.fn, btn));
});

// Search
const searchInput = document.getElementById('search');
searchInput.addEventListener('input', () => {
  const q = searchInput.value.toLowerCase();
  document.querySelectorAll('#fn-list button').forEach(btn => {
    btn.classList.toggle('hidden', q && !btn.dataset.name.includes(q));
  });
});

// Keys
document.addEventListener('keydown', e => {
  if (e.target === searchInput) {
    if (e.key === 'Escape') { searchInput.value = ''; searchInput.dispatchEvent(new Event('input')); searchInput.blur(); }
    return;
  }
  if (e.key === '/' || (e.key === 'f' && (e.metaKey || e.ctrlKey))) { e.preventDefault(); searchInput.focus(); return; }
  if (e.key === 'r' || e.key === 'R') { resetView(); return; }
  if (e.key === '=' || e.key === '+') { window.zoomIn(); return; }
  if (e.key === '-') { window.zoomOut(); return; }
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
    e.preventDefault();
    const btns = [...document.querySelectorAll('#fn-list button:not(.hidden)')];
    const idx = btns.findIndex(b => b.classList.contains('active'));
    const next = e.key === 'ArrowDown' ? Math.min(idx+1, btns.length-1) : Math.max(idx-1, 0);
    if (btns[next]) { show(btns[next].dataset.fn, btns[next]); btns[next].scrollIntoView({block:'nearest'}); }
  }
});
</script>
";
    }
}
