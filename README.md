# ChapterBinder

A local macOS app that turns already-ripped audio into a single **chaptered `.m4b`** that opens in Chapterline and Apple Books. Marketing version **1.1.0** (build 2). See `VERSION.md`.

Audio never leaves this Mac. Optional internet is used only for book lookup and cover art. Lookup failure does not fail an export.

## What it does

- **Import** folders of MP3 / M4A / AAC / WAV / AIFF / FLAC / existing M4B
- **Group many tracks into one chapter** (a CD track is not a book chapter)
- Edit chapters, cover art, and metadata in the three-pane binder
- **Export a real M4B** with Nero `moov/udta/chpl` and a QuickTime text chapter track (`tref/chap`)
- AAC that already matches the preset is copied. Chapters, cover, and tags are stamped without re-encoding

Audible `.aa` / `.aax` files are rejected. ChapterBinder does not unlock DRM.

There is no account, no analytics, and no third-party SDK.

## Target

| Target | Bundle ID | Sandbox | Helpers | CD rip |
| --- | --- | --- | --- | --- |
| `ChapterBinder-MAS` | `com.benmonroe.ChapterBinder.mas` | On | None | No |

The display name is ChapterBinder. 1.1.0 archives this target and does not upload to App Store Connect. See `APP_STORE_REVIEW.md`.

## Requirements

- macOS 14+
- Apple Silicon or Intel
- Xcode 16+ (Swift 6)
- Export uses the built-in encoder. Loudness normalize and silence trimming are unavailable. Detect Silence looks for an `ffmpeg` binary in `Contents/Helpers` and this app does not bundle one.

## Folder tree

```
ChapterBinder/
├── README.md
├── VERSION.md
├── APP_STORE_REVIEW.md
├── ChapterBinder.xcodeproj
├── ChapterBinderTests/
└── ChapterBinder/
    ├── ChapterBinderApp.swift
    ├── ContentView.swift
    ├── Info.plist
    ├── PrivacyInfo.xcprivacy
    ├── ChapterBinder-MAS.entitlements
    ├── Export/                   # timeline, Nero chpl, stamper, native export
    ├── App/AppModel.swift
    ├── Models/
    ├── Persistence/ProjectStore.swift
    ├── Player/AudiobookPlayer.swift
    ├── Services/
    ├── Views/
    └── Utilities/
```

## Data model

```
BookProject
  id, title, sortTitle, author, narrator, description, year
  series, seriesPart, genre, language, coverPath
  outputPreset, outputURL
  discs: [Disc]
  tracks: [SourceTrack]
  chapters: [Chapter]

Disc
  index, musicBrainzId?, rawTOC, ripStatus

SourceTrack
  id, path, bookmark, discIndex, trackIndex, duration
  originalTitle, codec, channels, sampleRate
  isRip, ripOK

Chapter
  id, title
  trackIDs: [SourceTrack.ID]   // 1…n tracks in order
  startOffset, endOffset       // intra-file splits (playhead markers)
  start, duration              // computed from real track durations
```

Merge tracks 4–7 into one chapter = one `Chapter` whose `trackIDs` are those four. Export writes **one marker** at the start of track 4; audio of 4–7 is contiguous. Chapter times are summed from probed durations, never guessed from filenames.

## Build

```bash
open ChapterBinder.xcodeproj
```

Scheme `ChapterBinder-MAS` is the sandboxed app. Product → Build (⌘B) or Archive. Do not upload the 1.1.0 archive.

## Entitlements

`ChapterBinder-MAS.entitlements`: app sandbox, user-selected read-write, app-scoped bookmarks, network client, Downloads read-write. Nothing else.

`PrivacyInfo.xcprivacy` sets tracking to false and lists no tracking domains.

## Notarization notes

```bash
xcodebuild -project ChapterBinder.xcodeproj -scheme ChapterBinder-MAS \
  -configuration Release -archivePath /tmp/ChapterBinder.xcarchive archive
```

The archive uses the sandbox entitlement. Uploading that archive is a later step, not 1.1.0.

## Keyboard

| Key | Action |
| --- | --- |
| Space | Play / pause |
| M | Merge selection |
| S | Split chapter into source files |
| Return | Rename chapter |
| ⌘I | Add files |
| ⌘E | Export |

## Export correctness

Chapterline 1.3.1 reads Nero `chpl` and AVFoundation chapter groups. ffmpeg `[CHAPTER]` blocks and `-movflags +use_metadata_tags` do **not** write the Nero atom Chapterline parses. Success is those two chapter tables.

When the project has N chapters and N ≥ 2, the file contains both:

1. `moov/udta/chpl` version 1, flags 0, count as a big-endian UInt32 at payload offset 4, starts in 100-nanosecond ticks
2. A QuickTime text chapter track with `tref/chap` on the audio track, so `AVURLAsset.loadChapterMetadataGroups` returns N groups

Also written: extension `.m4b`, major brand `M4B` (compatible brands include `mp42` and `isom`), integer iTunes `stik` = 2, title, artist, album, and `covr` when the project has a cover.

- Chapter times come from probed durations. `startOffset` / `endOffset` shift the timeline. Starts must increase by at least 0.1 seconds or the job fails before mux
- One chapter in the project writes one chapter
- A volume split writes one stamped `.m4b` per part, and that part’s chapter table starts at 0
- AAC-in-MP4 with a matching rate and channel count is stream-copied. Other sources encode to AAC-LC at the preset bitrate
- A missing `chpl` or `tref/chap` fails the job. The file is not left for Books to show as a single chapter
- The queue reports `12 chapters written (AV 12, Nero 12)`
- Temp files stay on the destination volume. They are deleted on success or cancel and kept on failure
- Finished files open with `NSWorkspace.shared.open`

## Projects

Saved as JSON in `~/Library/Application Support/ChapterBinder/Projects/`. Originals are referenced, not copied. Covers are stored beside the project. Each source track and the cover store an app-scoped security-scoped bookmark beside the path. Older JSON without those keys still opens. The app asks you to relink a file when its bookmark is stale.

The project cache is cleared after a successful export. `startAccessingSecurityScopedResource` is held while probing, playing, and exporting, and released when the project closes.
