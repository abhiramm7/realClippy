# Releasing StudyBuddy (DMG)

This repo ships:
- a GitHub Pages site (in `docs/`)
- a DMG build script (in `scripts/`)

## 1) Build DMG locally

```bash
chmod +x scripts/build_dmg.sh
./scripts/build_dmg.sh
```

Output:
- `dist/StudyBuddy.dmg`

## 2) Create a GitHub Release

1. Push your changes to `main`.
2. In GitHub → **Releases** → **Draft a new release**.
3. Tag it (e.g. `v0.1.0`).
4. Upload `dist/StudyBuddy.dmg` as a release asset.

Releases page:
- https://github.com/abhiramm7/realClippy/releases

## 3) Enable GitHub Pages

GitHub → **Settings** → **Pages**:
- Source: **Deploy from a branch**
- Branch: `main`
- Folder: `/docs`

After it builds, your site should be available at:

`https://abhiramm7.github.io/realClippy/`
