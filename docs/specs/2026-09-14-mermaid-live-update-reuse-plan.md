# Reuse unchanged Mermaid diagrams across live updates

## Problem

`MarkdownWebController.reloadContent()` replaces `.markdown-body.innerHTML`
wholesale, then calls `window.__mdqlRenderDiagrams()`. The swap discards every
rendered `.mdql-mermaid` wrapper and puts back raw
`<pre><code class="language-mermaid">` blocks, so every diagram in the file
goes back through `mermaid.render` (parse, layout, SVG) on every change on disk.
Until each render resolves, the reader sees raw fence source where the diagram
was. A checkbox toggle, which writes the file, makes every diagram flash.

## Approach

Keep the rendered wrapper nodes from before the swap, and put them back in
place of any new fence whose source is identical. Only new or edited fences
are rendered.

1. **Move the swap into the page.** Add `window.__mdqlSwapBody(html)` to the
   init script in `MarkdownRenderer.wrapInHTMLDocument`. `reloadContent()` calls
   it with the decoded body. The base64/`TextDecoder` decoding stays in Swift's
   JS string. This puts the harvest, swap, and reuse steps in one synchronous
   task, so nothing is painted between them.
2. **Harvest.** Before the swap, collect
   `.markdown-body .mdql-mermaid[data-mdql-source]` into a map from source text
   to a queue of nodes. Using a queue means duplicate identical fences each get
   their own node. Skip any wrapper whose `data-mdql-theme` doesn't match the
   current theme.
3. **Swap.** Set `innerHTML`.
4. **Reuse or render.** Give `__mdqlRenderDiagrams` an optional cache
   argument. For each unrendered `pre code.language-mermaid`, if the cache
   has a node for `code.textContent`, dequeue it and call
   `pre.replaceWith(node)`. Otherwise call `renderMermaid` as today. Moving
   the node, rather than rebuilding it, keeps its SVG ids and the listeners
   `bindFunctions` attached.
5. **Tag the theme.** `renderMermaid` sets `data-mdql-theme` (`dark`/`default`)
   on the wrapper. This covers a theme-change render that is still in flight
   during a swap. That render's `div.replaceWith(newDiv)` targets a detached
   node and does nothing, so the old-theme node could otherwise be reused.
   The tag lets step 2 skip that node, and the fence is rendered fresh.

Unchanged by this plan:
- Nodes left in the cache are dropped.
- Error blocks (`pre.mdql-mermaid-error`) are never cached, so a fixed fence
  re-renders.
- The full-reload branch for the first fence stays as it is.
- SVG ids stay unique because reused nodes keep their ids and `seq` never
  repeats.

## Tests

WKWebView tests in `MarkdownRendererTests` / `PreviewControllerTests`, using
`pollJS` and `reloadContent()`:

- **Unchanged diagrams are reused:** Start with a doc that has two fences and
  a paragraph, and wait for both SVGs. Set a marker property on each wrapper
  node, edit only the paragraph, and reload. Both wrappers must still carry
  the marker. In the same `evaluateJavaScript` call as the swap, no
  `pre code.language-mermaid` may remain.
- **Edited fence re-renders:** Change one fence's source. That wrapper must be
  new, and the other must keep its marker.
- **Duplicate fences:** Use two identical fences. After a prose edit, both
  nodes must be reused and neither may be dropped.
- **Theme race:** Flip `webView.appearance` and reload in the same run loop
  turn. Every final wrapper must have `data-mdql-theme="dark"`.
- **Mutation-check:** Disable the cache lookup and confirm the reuse test
  fails.

## Files

- `mdqlPreview/MarkdownRenderer.swift`: init script (`__mdqlSwapBody`, cache
  in `__mdqlRenderDiagrams`, theme tag in `renderMermaid`)
- `mdqlPreview/MarkdownWebController.swift`: `reloadContent()` calls
  `__mdqlSwapBody`
- `mdqlTests/*`: tests above
- `docs/live-updates.md`: note that diagrams are reused
