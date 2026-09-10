# Bundled helpers

Drop **universal** (arm64 + x86_64) binaries here. The Xcode build copies them to `ChapterBinder.app/Contents/Helpers`.

| Binary | Purpose |
| --- | --- |
| `ffmpeg` | Encode, concat, mux M4B, chapters, cover, tags |
| `ffprobe` | Probe duration/codec/tags/chapters and **verify** exports |
| `cdparanoia` or `cd-paranoia` | Jitter-corrected CD rips to WAV |

Do **not** ship Homebrew’s cellar-linked `ffmpeg`. Use a static macOS build (evermeet, ffmpeg.org, or a local static compile).

```bash
# example
cp /path/to/static/ffmpeg ./ffmpeg
cp /path/to/static/ffprobe ./ffprobe
chmod +x ffmpeg ffprobe
```

Runtime search order: `Contents/Helpers` → Homebrew → `/usr/local/bin` → `PATH`.
