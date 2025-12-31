# StudyBuddy

A macOS PDF reader with a built-in chat assistant powered by a **local Ollama model**.

Use it to:
- Open a PDF (textbook/paper)
- Search inside the PDF (PDFKit)
- Ask questions in chat
- Optionally highlight text in the PDF to use *that exact selection* as chat context

---

## Requirements

- macOS
- [Ollama](https://ollama.com) installed and running

---

## Download or Build

### Use the pre-built DMG (recommended)

If a `dist/StudyBuddy.dmg` file is present in this repository or a GitHub Release, you can install the app without building:

- Download the DMG from the `dist/` folder: https://github.com/abhiramm7/realClippy/blob/main/dist/StudyBuddy.dmg
- Open the DMG and drag `StudyBuddy` to the `Applications` folder.


### Or build from source

See below for Ollama setup and build instructions if you want to build it yourself.

---

## Setup (Ollama)

### 1) Install Ollama

Download and install from:
- https://ollama.com

### 2) Start Ollama

After installation, Ollama runs locally and exposes an HTTP API at:
- `http://localhost:11434`

Quick check:

```bash
curl -sS http://localhost:11434/api/version | cat
```

### 3) Download the default model

This app’s default chat model is configured in `StudyBuddy/config.json`:
- `defaults.ollamaChatModel`: `ministral-3:3b`

Pull it:

```bash
ollama pull ministral-3:3b
```

(Optional) list installed models:

```bash
ollama list
```

---

## Run / Build

### Open in Xcode

```bash
open StudyBuddy.xcodeproj
```

### Build from CLI

```bash
xcodebuild -project StudyBuddy.xcodeproj \
  -scheme StudyBuddy \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

---

## Configuration

Defaults live in:
- `StudyBuddy/config.json`

You can also override values in-app via **Settings** (gear icon).
