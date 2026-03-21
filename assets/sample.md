# mdql Preview

A **bold** statement with *italic flair* and ~~strikethrough~~. Here's `inline code` and a [link](https://github.com).

- [x] Live preview with FileWatcher
- [x] Dark mode support
- [ ] Incremental DOM updates

```swift
let html = MarkdownRenderer.render(fileAt: url)
webView.loadHTMLString(html, baseURL: nil)
```

| Feature | Status | Feature | Status |
|---------|--------|---------|--------|
| GFM tables | Yes | Task lists | Yes |
| Strikethrough | Yes | Live reload | Yes |

> "Any sufficiently advanced technology is indistinguishable from magic." — Arthur C. Clarke

---

1. First item with `code`
   - Sub-item with **bold** and *emphasis*
2. Second item
   1. Ordered sub-item
