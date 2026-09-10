# ChapterBinder

A local, offline-first macOS app that turns audiobook CDs and already-ripped audio into a single **chaptered `.m4b`** that works in Apple Books, CarPlay, iPhone, Audiobookshelf, Plex, and VLC.

Audio never leaves this Mac. Optional internet is used only for disc/book lookup and cover art.

## What it does

- **Rip** an audio CD (USB SuperDrive / generic USB DVD — modern Macs have no built-in drive)
- **Import** folders of MP3 / M4A / AAC / WAV / AIFF / FLAC / existing M4B
- **Group many tracks into one chapter** (a CD track is not a book chapter)
- Edit chapters, cover art, and metadata
- **Export a real M4B**, or chapterize an existing M4B with stream copy (`-c copy`) — no AAC re-encode just to change chapters, cover, or tags

Not in v1: Audible AAX/AA DRM stripping, cloud accounts, a music-library manager, or the App Store sandbox.

## Requirements

- macOS 14+
- Apple Silicon or Intel
- Xcode 16+ (Swift 6)
- Bundled **ffmpeg** + **ffprobe** for export
- Bundled **cdparanoia** / **libcdio-paranoia** for ripping (the UI also has a mock TOC so you can develop without a drive)

## Folder tree

```
ChapterBinder/
├── README.md
├── Helpers/                      # drop static ffmpeg, ffprobe, cdparanoia here
├── scripts/bundle-helpers.sh     # Xcode run script → Contents/Helpers
├── ChapterBinder.xcodeproj
└── ChapterBinder/
    ├── ChapterBinderApp.swift
    ├── ContentView.swift
    ├── Info.plist
    ├── ChapterBinder.entitlements
    ├── App/AppModel.swift
    ├── Models/                   # BookProject, Disc, SourceTrack, Chapter, presets
    ├── Persistence/ProjectStore.swift
    ├── Player/AudiobookPlayer.swift
    ├── Services/                 # import, probe, export, CD, MusicBrainz, silence
    ├── Views/                    # three-pane UI
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
  id, url, discIndex, trackIndex, duration
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

The app target is **not sandboxed** (`ENABLE_APP_SANDBOX = NO`) so ffmpeg and raw optical-drive access stay sane. Hardened Runtime is on for notarization.

1. Put `ffmpeg` and `ffprobe` in `Helpers/` (see that folder’s README).
2. Optionally put `cdparanoia` there too (`brew install cdparanoia` is fine for local work).
3. Product → Build (⌘B) or Archive.

The Run Script phase `scripts/bundle-helpers.sh` copies helpers into `ChapterBinder.app/Contents/Helpers`.

### Homebrew (local development only)

```bash
brew install ffmpeg cdparanoia
```

Homebrew binaries are **not** relocatable. They work when the Cellar is present on your machine. For a build you will notarize and send to someone else, use static universal binaries in `Helpers/`.

## Bundled helpers

| Path in the `.app` | Binary |
| --- | --- |
| `Contents/Helpers/ffmpeg` | encode / concat / mux |
| `Contents/Helpers/ffprobe` | probe + export verification |
| `Contents/Helpers/cdparanoia` | CD rip with jitter correction |

Runtime lookup: bundle Helpers → `/opt/homebrew/bin` → `/usr/local/bin` → `PATH`.

If paranoia is missing, the ripper interface still exists; the mock TOC path writes silent WAVs so the rest of the app can be developed. A future fallback is `ffmpeg -f libcdio`.

## Entitlements

v1 is a **direct download**, not App Store sandboxed.

`ChapterBinder.entitlements`:

- `com.apple.security.cs.disable-library-validation` — ffmpeg and its dylibs
- `com.apple.security.cs.allow-unsigned-executable-memory` — some ffmpeg builds
- `com.apple.security.device.dvd` — optical drive
- `com.apple.security.network.client` — MusicBrainz / Cover Art Archive / Open Library / Google Books
- User-selected files read-write (harmless with sandbox off; required if you turn sandbox on later)

Hardened Runtime stays enabled.

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

`ExportOptions.plist` should use `method = developer-id` (Developer ID Application), **not** `app-store`.

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

- Probe every file (ffprobe, AVFoundation fallback)
- Ordered `SourceTrack` list, then `Chapter` list that owns 1…n tracks
- Chapter start times from **actual** durations
- AAC matching + bind/chapters only → concat demuxer + `-c copy`
- Existing M4B chapter/cover/tag edit → remux only
- Otherwise encode AAC, concat, mux
- `ffmetadata` with global tags + `[CHAPTER]` (`TIMEBASE=1/1000`)
- Mux to `.m4b` with **major brand `M4B`** and **`media_type=2`** (iTunes `stik` = Audiobook) so Books files it under Audiobooks, not Music
- QuickTime chapters via ffmetadata; Nero `chpl` via `-movflags +use_metadata_tags`
- Verify with ffprobe: chapter count, duration, tags, cover. **Missing chapters fail the job.**
- Temp files on the destination volume. Delete on success or cancel; keep on failure.

If chapters do not show in Apple Books, that is a bug, not a known limitation.

## CD ripper

- DiskArbitration + IOKit watch for `CD_DA` / `IOCDMedia`
- USB unplug mid-rip is treated as the disc disappearing
- Rips land in `~/Library/Application Support/ChapterBinder/Cache/<project>/discN/` as 16-bit 44.1 kHz WAV
- Multi-disc: “This is disc N of this book”
- **Insert Mock Audio CD** (Disc menu) when this machine has no drive

## Projects

Saved as JSON in `~/Library/Application Support/ChapterBinder/Projects/`. Originals are referenced, not copied, except CD rips, covers, and encode temps. Rip cache is cleared after a successful export.
