# StudyBuddy (PDF Reader + Ollama Chat)

A macOS PDF reader that pairs your textbook/research paper with a local Ollama chatbot. The goal is a “study buddy” experience: ask questions, get answers grounded in the PDF.

---

## Share this app (GitHub Pages + DMG)

### GitHub Pages site

This repo includes a GitHub Pages site in `docs/`.

To enable it:
1. GitHub → **Settings** → **Pages**
2. Source: **Deploy from a branch**
3. Branch: `main`
4. Folder: `/docs`

### DMG for others to install

A simple DMG builder script is included:

```bash
chmod +x scripts/build_dmg.sh
./scripts/build_dmg.sh
```

It produces:
- `dist/StudyBuddy.dmg`

Upload that DMG to **GitHub Releases** so others can download it.

---

## Quick health checks (Ollama)

### 1) Check Ollama is running

```shell
curl -sS http://localhost:11434/api/version | cat
```

### 2) List installed models

```shell
curl -sS http://localhost:11434/api/tags | cat
```

### 3) Smoke-test the chat model (non-stream)

```shell
curl -sS http://localhost:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ministral-3:3b",
    "messages": [{"role":"user","content":"Reply with exactly: OK"}],
    "stream": false
  }' | cat
```

> Note: the app uses streaming (`stream: true`) in `ChatService.swift`, but the non-stream call above is the simplest “is it working?” check.

---

## How the app talks to Ollama (code pointers)

- `ConfigManager.swift`
  - `ollamaBaseURL` (default: `http://localhost:11434`)
  - `ollamaChatModel` (default: `ministral-3:3b`)
  - request timeout (`chatTimeout`)
- `ChatService.swift`
  - `POST /api/chat` with `stream: true`
  - parses newline-delimited JSON chunks (`done`, `message.content`)
  - injects a system prompt + optional `<context>...</context>`

---

## Build log (turn this into the blog later)

Use this section as your daily development journal. When you’re ready to publish, you can copy/paste the best entries into a polished blog post.

### 2025-12-31

**What I built / changed**
- Verified Ollama is reachable locally (`/api/version`).
- Verified installed models include `ministral-3:3b`.
- Confirmed `/api/chat` returns a response via `curl`.

**What worked**
- ✅ `POST /api/chat` returned `OK` in a minimal test.

**What didn’t / gotchas**
- On macOS, `timeout` isn’t available by default in zsh. If needed for streaming tests, use `gtimeout` (coreutils) or just test using non-stream.

**Next steps**
- Add UI to choose model + show when Ollama is offline.
- Improve RAG: better snippet selection, more context characters, citations that jump to pages.

---

## Blog draft outline

Working title: **“Building a macOS PDF Study Buddy with SwiftUI, PDFKit, and Ollama”**

1. Motivation: why a local-first “study buddy”
2. Architecture overview
   - SwiftUI UI + PDFKit
   - Text extraction + search/index
   - RAG: choosing context snippets
   - Streaming chat from Ollama
3. Implementation notes
   - Handling streaming JSON chunks
   - Prompt design & context formatting (`<context>...</context>`)
   - Performance + UX tradeoffs (fast mode)
4. Lessons learned
   - Latency, model choice, prompt size limits
   - PDF text extraction quirks
5. What’s next
   - Better citations + page navigation
   - Embeddings + semantic search
   - Summarization / flashcards
