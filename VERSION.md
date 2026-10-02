# VERSION

App: ChapterBinder
Bundle ID: com.benmonroe.ChapterBinder
MAS bundle ID: com.benmonroe.ChapterBinder.mas
Platforms: macOS 14+
Xcode: 16+ / 26+
Swift: 6
Marketing version source of truth: this file + Xcode MARKETING_VERSION
Build number source of truth: Xcode CURRENT_PROJECT_VERSION (integer, monotonic)

## Current

- Marketing: 1.1.0
- Build: 2
- Channel: local
- Date: 2026-10-02
- Git: main (bnb549/ChapterBinder) — apply on top of 1.0 / f86944d

## SemVer rules

- MAJOR: breaking project-file format, dropped macOS support, or a chapter atom Chapterline 1.3.1 cannot read
- MINOR: user-visible features that stay backward compatible
- PATCH: fixes, polish, copy
- Build number: increment on every archive, even if marketing version is unchanged
- Do not renumber com.benmonroe.ChapterBinder

## History

### 1.1.0 — 2026-10-02 — build 2

- MINOR. Chapterline-readable export and a sandboxed MAS target.
- Native Nero chpl (version 1, count at offset 4, 100 ns ticks) plus QuickTime tref/chap. ffprobe is not the pass condition.
- ffmpeg is an optional Developer ID encode fallback. MAS target bundles no helpers and does not rip CDs.
- Security-scoped bookmarks on source tracks.
- Known limits: App Store Connect upload is not this build. Optical ripping is direct-download only.

### 1.0 — pre-ledger — build 1

- Unsandboxed direct download. ffmpeg ffmetadata chapters. Verification was ffprobe-only.
