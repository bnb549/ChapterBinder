# App Store review notes

ChapterBinder 1.1.0 (build 2) is a local audiobook chapter editor for macOS 14 and later. This build is archived so a later submission is possible. It is not uploaded to App Store Connect.

## On device

- The user imports DRM-free AAC, MP3, WAV, FLAC, or an existing M4B.
- Chapter titles, cover, and author are edited on the Mac.
- Export writes one `.m4b`. Audio is encoded and chapter atoms are stamped on device. Audio is never uploaded.
- A sample 3-chapter `.m4b` (one title is non-ASCII, `Ümlaut`) is the file to open in Chapterline. Chapterline is a separate app and is not embedded here.

## Optional lookup

Cover and metadata lookup may contact MusicBrainz, the Cover Art Archive, Open Library, and Google Books. If lookup fails, export continues offline. There is no account and no analytics.

`PrivacyInfo.xcprivacy` sets `NSPrivacyTracking` to false and lists no tracking domains.

## Not in the store build

- No CD ripping. The optical-drive watcher and cdparanoia are compiled out with `APP_STORE`. The Disc menu is hidden. Ripping ships only in the direct-download build.
- No bundled ffmpeg, ffprobe, or other helper. `Contents/Helpers` is absent.
- Entitlements are sandbox, user-selected read-write, app-scoped bookmarks, network client, and Downloads read-write.

The direct-download bundle ID stays `com.benmonroe.ChapterBinder`. This target uses `com.benmonroe.ChapterBinder.mas` so the two builds can be installed side by side. The display name is ChapterBinder on both.
