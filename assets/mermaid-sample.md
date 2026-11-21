# Mermaid in mdql

A ` ```mermaid ` fence renders as a diagram, in Quick Look and in the viewer alike. The text shows first; the diagrams follow a moment later, drawn in light or dark to match the system. Nothing is fetched: the Mermaid runtime ships inside mdql.

## Flowchart: how a preview is put together

```mermaid
flowchart TB
    QL(["Finder Quick Look — Space on a .md file"])

    subgraph app["mdql.app"]
        direction TB

        subgraph appex["mdqlPreview.appex — sandboxed"]
            direction TB
            PC["PreviewController<br/><i>view-based preview</i>"]
            MWC["MarkdownWebController<br/><i>WKWebView + script message handler</i>"]
            MR["MarkdownRenderer<br/>swift-markdown (cmark-gfm)"]
            MM["MermaidRuntime<br/>mermaid.min.js, served to the page<br/>only when it has a diagram"]
            FW["FileWatcher<br/>DispatchSource · atomic-save recovery<br/>100 ms coalescing"]
            WV["WKWebView"]
        end

        subgraph xpc["open-url.xpc — unsandboxed"]
            OS["OpenURLService<br/>open · readFile · toggleCheckbox"]
        end

        DWC["DocumentWindowController<br/><i>standalone viewer window</i>"]
    end

    MD[("markdown file on disk")]
    BR(["default browser"])

    QL --> PC --> MWC
    MWC --> MR
    MR -->|"HTML"| WV
    MM -.->|"after the text"| WV
    MD --> FW
    FW -->|"body-only re-render,<br/>base64 innerHTML swap"| WV
    WV -->|"link clicks & checkbox toggles<br/>(WKScriptMessageHandler)"| MWC
    MWC -->|"openURL"| OS
    OS --> BR
    MWC -->|"readFile — linked sibling .md"| OS
    MWC -->|"toggleCheckbox — single-byte write"| OS
    OS --> MD
    DWC -.->|"same engine, direct calls — no XPC"| MWC
```

## Sequence diagram: a live update

```mermaid
sequenceDiagram
    participant E as Editor
    participant FW as FileWatcher
    participant C as MarkdownWebController
    participant P as Page
    E->>FW: saves notes.md
    FW->>C: changed (coalesced over 100 ms)
    C->>C: renderBody(markdown)
    C->>P: swap the article's HTML
    P->>P: put unchanged diagrams back, draw new ones
```

## State diagram: a task-list checkbox

```mermaid
stateDiagram-v2
    [*] --> Unchecked
    Unchecked --> Writing: click
    Checked --> Writing: click
    Writing --> Checked: byte written, was [ ]
    Writing --> Unchecked: byte written, was [x]
    Writing --> Rendered: the file changed since
    Rendered --> Unchecked
    Rendered --> Checked
```

## Class diagram: what each host gives the engine

```mermaid
classDiagram
    class MarkdownWebController {
        +WKWebView webView
        +openURL(URL)
        +readFile(URL)
        +toggleCheckbox(offset, checked)
    }
    class PreviewController {
        XPC connection
    }
    class DocumentWindowController {
        direct file access
    }
    PreviewController --> MarkdownWebController : closures over XPC
    DocumentWindowController --> MarkdownWebController : direct closures
```

## Pie chart: where an open spends its time

```mermaid
pie showData
    title Opening a short note (ms, illustrative)
    "Render the Markdown" : 1
    "Load the page" : 45
    "Draw the diagrams" : 5
```
