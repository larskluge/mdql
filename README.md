# mdql

A macOS Quick Look extension for previewing Markdown files. Press Space on any `.md` file in Finder to see a rendered preview — with **live updates** as the file changes.

## Features

- **Live preview** — edit a Markdown file and watch the QuickLook preview update in real-time
- **GitHub Flavored Markdown** — tables, task lists, strikethrough, fenced code blocks with language hints
- **Light & dark mode** — automatically follows system appearance
- **Inkpad-inspired styling** — clean typography with thoughtful spacing and color tokens
- **Fast** — uses Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown) (cmark-gfm) for native-speed parsing

## Install

1. Open `mdql.xcodeproj` in Xcode
2. Build & Run (Cmd+R)
3. Copy the built app to `~/Applications`:
   ```bash
   cp -R ~/Library/Developer/Xcode/DerivedData/mdql-*/Build/Products/Debug/mdql.app ~/Applications/mdql.app
   qlmanage -r
   ```
4. Press Space on any `.md` file in Finder

## Build

```bash
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' build
```

## Test

```bash
xcodebuild -project mdql.xcodeproj -scheme mdql -destination 'platform=macOS' test
```

## Requirements

- macOS 12.0+
- Xcode 15.0+
