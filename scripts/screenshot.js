#!/usr/bin/env node
// Renders a markdown file to HTML (matching MarkdownRenderer.swift output)
// and screenshots it with puppeteer.
//
// Usage: node scripts/screenshot.js <input.md> <output.png> [width] [height]

const fs = require("fs");
const os = require("os");
const path = require("path");

async function main() {
  const args = process.argv.slice(2);
  if (args.length < 2) {
    console.error("Usage: screenshot.js <input.md> <output.png> [width] [height]");
    process.exit(1);
  }

  const [mdPath, outPath] = args;
  const width = parseInt(args[2] || "1200", 10);
  const height = parseInt(args[3] || "900", 10);

  const markdown = fs.readFileSync(mdPath, "utf-8");
  const cssPath = path.resolve(__dirname, "../mdqlPreview/Resources/preview.css");
  const css = fs.readFileSync(cssPath, "utf-8");

  // Parse front matter (same logic as MarkdownRenderer.parseFrontMatter)
  const { pairs, body } = parseFrontMatter(markdown);

  // Render markdown to HTML using marked with GFM
  const { marked } = require("marked");
  marked.setOptions({ gfm: true, breaks: false });
  const bodyHTML = marked.parse(body);

  // Render front matter HTML (same structure as MarkdownRenderer.renderFrontMatter)
  let frontMatterHTML = "";
  if (pairs.length > 0) {
    const items = pairs.map(
      ([k, v]) =>
        `<span class="fm-key">${escapeHTML(k)}:</span> ${escapeHTML(v)}`
    );
    frontMatterHTML = `<div class="front-matter">${items.join(' <span class="fm-sep">\u00b7</span> ')}</div>\n`;
  }

  const title = path.basename(mdPath, path.extname(mdPath));

  // Same HTML structure as MarkdownRenderer.wrapInHTMLDocument
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHTML(title)}</title>
<style>
${css}
</style>
</head>
<body>
<article class="markdown-body">
${frontMatterHTML}${bodyHTML}
</article>
</body>
</html>`;

  // Write HTML to a temp file and use page.goto(file://) to avoid setContent timeout
  const tmpHtml = path.join(os.tmpdir(), `mdql-preview-${Date.now()}.html`);
  fs.writeFileSync(tmpHtml, html, "utf-8");

  // Screenshot with puppeteer
  const puppeteer = require("puppeteer");
  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-setuid-sandbox", "--disable-dev-shm-usage"],
  });
  try {
    const page = await browser.newPage();
    await page.setViewport({ width, height, deviceScaleFactor: 2 });

    // Force light mode (matches the default QuickLook appearance)
    await page.emulateMediaFeatures([
      { name: "prefers-color-scheme", value: "light" },
    ]);

    // Use file:// URL instead of setContent — avoids navigation timeout on CI
    await page.goto(`file://${tmpHtml}`, { waitUntil: "load", timeout: 60000 });

    // Ensure output directory exists
    fs.mkdirSync(path.dirname(outPath), { recursive: true });

    await page.screenshot({ path: outPath, type: "png" });
    console.log(`Screenshot saved to ${outPath} (${width}x${height}@2x)`);
  } finally {
    await browser.close();
    fs.unlinkSync(tmpHtml);
  }
}

function parseFrontMatter(markdown) {
  const trimmed = markdown.replace(/^\n+/, "");
  if (!trimmed.startsWith("---")) return { pairs: [], body: markdown };

  const lines = markdown.split("\n");

  // Find opening ---
  let openIndex = null;
  for (let i = 0; i < lines.length; i++) {
    const stripped = lines[i].trim();
    if (stripped === "") continue;
    if (stripped === "---") {
      openIndex = i;
      break;
    } else {
      return { pairs: [], body: markdown };
    }
  }
  if (openIndex === null) return { pairs: [], body: markdown };

  // Find closing ---
  let closeIndex = null;
  for (let i = openIndex + 1; i < lines.length; i++) {
    if (lines[i].trim() === "---") {
      closeIndex = i;
      break;
    }
  }
  if (closeIndex === null) return { pairs: [], body: markdown };

  // Parse key: value pairs
  const pairs = [];
  for (let i = openIndex + 1; i < closeIndex; i++) {
    const colonIdx = lines[i].indexOf(":");
    if (colonIdx === -1) continue;
    const key = lines[i].substring(0, colonIdx).trim();
    const value = lines[i].substring(colonIdx + 1).trim();
    if (key) pairs.push([key, value]);
  }

  // Sort alphabetically (same as Swift version)
  pairs.sort((a, b) => a[0].localeCompare(b[0], undefined, { sensitivity: "base" }));

  const body = lines.slice(closeIndex + 1).join("\n");
  return { pairs, body };
}

function escapeHTML(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
