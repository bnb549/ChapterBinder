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

## Targets

| Target | Bundle ID | Sandbox | Helpers | CD rip |
| --- | --- | --- | --- | --- |
| `ChapterBinder` | `com.benmonroe.ChapterBinder` | Off. Hardened Runtime on | Optional static binaries in `Contents/Helpers` | Yes |
| `ChapterBinder-MAS` | `com.benmonroe.ChapterBinder.mas` | On | None | Compiled out |

Both show the name ChapterBinder. The store build can sit beside the direct-download build. Ripping is direct-download only. 1.1.0 archives the store target and does not upload to App Store Connect. See `APP_STORE_REVIEW.md`.

## Requirements

- macOS 14+
- Apple Silicon or Intel
- Xcode 16+ (Swift 6)
- ffmpeg is **not** required to export. It is an optional Developer ID fallback for loudness normalize, silence trimming, and files AVFoundation cannot decode

## Folder tree

```
ChapterBinder/
├── README.md
├── VERSION.md
├── APP_STORE_REVIEW.md
├── Helpers/                      # optional static ffmpeg, ffprobe, cdparanoia
├── scripts/bundle-helpers.sh     # Developer ID run script only
├── ChapterBinder.xcodeproj
├── ChapterBinderTests/
└── ChapterBinder/
    ├── ChapterBinderApp.swift
    ├── ContentView.swift
    ├── Info.plist
    ├── PrivacyInfo.xcprivacy
    ├── ChapterBinder.entitlements
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

Scheme `ChapterBinder` is the direct-download app (`ENABLE_APP_SANDBOX = NO`, Hardened Runtime on). Scheme `ChapterBinder-MAS` is the sandboxed archive. Product → Build (⌘B) or Archive. Do not upload the 1.1.0 archive.

Helpers are optional. If you have static binaries, put them in `Helpers/` and the Developer ID Run Script copies them into `Contents/Helpers`. The script does not copy Homebrew. The MAS target has no helper script.

## Optional helpers

| Path in the direct-download `.app` | Binary |
| --- | --- |
| `Contents/Helpers/ffmpeg` | Loudness, silence trim, encode fallback |
| `Contents/Helpers/ffprobe` | Diagnostic chapter count only |
| `Contents/Helpers/cdparanoia` | CD rip on the direct-download build |

Runtime lookup is `Contents/Helpers` only. A missing helper does not block export.

## Entitlements

`ChapterBinder.entitlements` (direct download): library validation off, unsigned executable memory, optical drive, network client, user-selected files, Downloads. No Apple Events. Sandbox off.

`ChapterBinder-MAS.entitlements`: app sandbox, user-selected read-write, app-scoped bookmarks, network client, Downloads read-write. Nothing else.

`PrivacyInfo.xcprivacy` sets tracking to false and lists no tracking domains.

## Notarization notes

```bash
# Archive in Xcode, or:
xcodebuild -project ChapterBinder.xcodeproj -scheme ChapterBinder \
  -configuration Release -archivePath /tmp/ChapterBinder.xcarchive archive

xcodebuild -exportArchive -archivePath /tmp/ChapterBinder.xcarchive \
  -exportPath /tmp/ChapterBinderExport -exportOptionsPlist ExportOptions.plist

# Staple after notarytool
xcrun notarytool submit ChapterBinder.zip --apple-id ... --team-id ... --wait
xcrun stapler staple ChapterBinder.app
```

`ExportOptions.plist` for the direct-download archive should use `method = developer-id` (Developer ID Application). The MAS scheme archives locally with the sandbox entitlement. Uploading that archive is a later step, not 1.1.0.

Sign the bundled helpers too:

```bash
codesign --force --options runtime --sign "Developer ID Application: …" \
  ChapterBinder.app/Contents/Helpers/ffmpeg \
  ChapterBinder.app/Contents/Helpers/ffprobe
```

Then sign the `.app` last.

If Gatekeeper blocks ffmpeg, you likely forgot `disable-library-validation` or signed helpers after the app.

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

Chapterline 1.3.1 reads Nero `chpl` and AVFoundation chapter groups. ffmpeg `[CHAPTER]` blocks and `-movflags +use_metadata_tags` do **not** write the Nero atom Chapterline parses. ffprobe’s chapter count is a diagnostic, not success.

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

## CD ripper

Direct-download target only. The App Store build hides the Disc menu and compiles out `CDRipService` and `OpticalDriveWatcher`.

- DiskArbitration + IOKit watch for `CD_DA` / `IOCDMedia`
- USB unplug mid-rip is treated as the disc disappearing
- Rips land in `~/Library/Application Support/ChapterBinder/Cache/<project>/discN/` as 16-bit 44.1 kHz WAV
- Multi-disc: “This is disc N of this book”
- **Insert Mock Audio CD** (Disc menu) when this machine has no drive

## Projects

Saved as JSON in `~/Library/Application Support/ChapterBinder/Projects/`. Originals are referenced, not copied, except CD rips, covers, and encode temps. Each source track and the cover store an app-scoped security-scoped bookmark beside the path. Older JSON without those keys still opens. The sandboxed app asks you to relink a file when its bookmark is stale. The direct-download app falls back to the path.

Rip cache is cleared after a successful export. `startAccessingSecurityScopedResource` is held while probing, playing, and exporting, and released when the project closes.
