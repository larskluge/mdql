# mkql

A macOS Quick Look extension for previewing Markdown files. Press Space on any `.md` file in Finder to see a rendered preview.

## Features

- **GitHub Flavored Markdown** — tables, task lists, strikethrough, fenced code blocks with language hints
- **Light & dark mode** — automatically follows system appearance
- **Inkpad-inspired styling** — clean typography with thoughtful spacing and color tokens
- **Fast** — uses Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm) for native-speed parsing

## Install

1. Open `mkql.xcodeproj` in Xcode
2. Build & Run (Cmd+R)
3. The extension registers automatically — press Space on any `.md` in Finder

If the extension doesn't appear, reset the Quick Look cache:

```
qlmanage -r
```

## Build

```bash
xcodebuild -project mkql.xcodeproj -scheme mkql -destination 'platform=macOS' build
```

## Test

```bash
xcodebuild -project mkql.xcodeproj -scheme mkql -destination 'platform=macOS' test
```

## Requirements

- macOS 12.0+
- Xcode 15.0+
