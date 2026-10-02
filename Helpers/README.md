# Optional helpers

Drop **static universal** (arm64 + x86_64) binaries here. The Developer ID target’s Run Script copies them to `ChapterBinder.app/Contents/Helpers`.

| Binary | Used for |
| --- | --- |
| `ffmpeg` | Loudness normalize, silence trimming, and encode when AVFoundation cannot |
| `ffprobe` | Diagnostic chapter count only. It does not decide export success |
| `cdparanoia` or `cd-paranoia` | CD ripping on the direct-download build |

The Mac App Store target does not run this script and does not rip CDs.

Export of AAC, MP3, WAV, and FLAC does not need these binaries. Homebrew is not searched at build time or at runtime.

```bash
cp /path/to/static/ffmpeg ./ffmpeg
cp /path/to/static/ffprobe ./ffprobe
chmod +x ffmpeg ffprobe
```

Do **not** ship Homebrew’s cellar-linked `ffmpeg`.
