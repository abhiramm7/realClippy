---
layout: default
title: StudyBuddy
---

# StudyBuddy

A macOS PDF reader that pairs your textbook/research paper with a local Ollama chatbot.

## Download

- **DMG (recommended):** download the latest installer from
  [GitHub Releases](https://github.com/abhiramm7/realClippy/releases).
- **Source:** clone this repo and build in Xcode.

## What it does

- Open and read a PDF with PDFKit.
- Ask questions in the chat panel.
- Highlight text to use it as context (and skip the slower search pipeline).
- Search the PDF using PDFKit, with results shown in the left sidebar.

## Requirements

- macOS + Xcode (to build from source)
- [Ollama](https://ollama.com) running locally

## Quick Ollama checks

```shell
curl -sS http://localhost:11434/api/version | cat
curl -sS http://localhost:11434/api/tags | cat
```

## Build & Run

```shell
# Open the project in Xcode
open StudyBuddy.xcodeproj

# Or build from the CLI
xcodebuild -project StudyBuddy.xcodeproj \
  -scheme StudyBuddy \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

## DMG build (for sharing)

```shell
chmod +x scripts/build_dmg.sh
./scripts/build_dmg.sh
```

This produces:
- `dist/StudyBuddy.dmg`

## Notes

- Default Ollama base URL and model are configured in `StudyBuddy/config.json` (overridable in Settings).

## Screenshots

Add screenshots to `docs/assets/` and reference them here, for example:

```markdown
![Main UI](assets/screenshot-main.png)
```
