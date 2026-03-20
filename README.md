<div align="center">

# Lumina

**Your personal media library for macOS**

A native macOS app for organizing and playing photos, videos, and audio — with built-in support for MKV, AVI, WMV and 30+ formats via bundled FFmpeg.

[Download →](https://github.com/likhith1542/lumina/releases) · [Landing Page](https://likhith1542.github.io/lumina) · [Report Bug](https://github.com/likhith1542/lumina/issues)

![macOS](https://img.shields.io/badge/macOS-14.0%2B-black?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-5.9-orange?style=flat-square&logo=swift)
![License](https://img.shields.io/badge/License-MIT-blue?style=flat-square)
![FFmpeg](https://img.shields.io/badge/FFmpeg-GPL%20v2-green?style=flat-square)
![Build](https://img.shields.io/badge/build-passing-brightgreen?style=flat-square)

</div>

---

## Screenshots


---

## Features

### 📸 Photos
- Pan, zoom, and navigate with smooth gestures
- Supports JPEG, PNG, HEIC, AVIF, WebP, GIF, TIFF
- RAW formats: NEF, CR2, CR3, ARW, ORF, RAF, DNG, RW2

### 🎬 Videos
- Native playback for MP4, MOV, M4V
- MKV, AVI, WMV, FLV, WebM and more via bundled FFmpeg
- Full playback controls — seek, speed, volume, fullscreen
- Subtitle support: SRT, ASS, VTT (external files + auto-extracted from MKV)
- Multi-language audio track selection for MKV files
- Resume playback from where you left off

### 🎵 Audio
- 10-band parametric equalizer (±24 dB per band)
- Real-time spectrum visualizer
- Queue management with shuffle and loop modes
- Album art display
- Supports MP3, AAC, FLAC, WAV, AIFF, OGG, OPUS, WMA, ALAC

### 📁 Library
- Add folders — Lumina watches them automatically
- New files appear instantly; deleted files disappear immediately
- Grid and list views
- Sort by date modified, title, duration, file size, or play count
- Search across your entire library
- Favorites, playlists, and Recently Played
- First-launch onboarding guide

---

## Installation

### Requirements
- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

### Steps

1. Download `Lumina-1.0.0.zip` from [Releases](https://github.com/likhith1542/lumina/releases)
2. Unzip and move `Lumina.app` to your `/Applications` folder
3. **Right-click → Open** on first launch (app is not notarized)
4. Click `+` to add a media folder and start building your library

> **Why right-click → Open?** Lumina bundles FFmpeg which is GPL-licensed and cannot be notarized through Apple's notarization service. Your Mac is safe — this is a standard step for apps distributed outside the App Store.

---

## Building from Source

### Prerequisites
- Xcode 15 or later
- macOS 14.0+ SDK
- ffmpeg binaries (arm64 + x86_64) — included via Git LFS

### Clone and build

```bash
git clone https://github.com/likhith1542/lumina.git
cd lumina
git lfs pull   # downloads ffmpeg binaries
open lumina.xcodeproj
```

Then in Xcode: **Product → Run** (`⌘R`)

### Dependencies

| Dependency | Version | Purpose |
|---|---|---|
| [GRDB](https://github.com/groue/GRDB.swift) | 6.x | SQLite database |
| FFmpeg (bundled) | Latest | MKV/AVI/WMV transcoding |

---

## FFmpeg & Licensing

Lumina bundles a statically compiled FFmpeg binary for **Apple Silicon (arm64)** and **Intel (x86_64)**, sourced from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de).

| Component | License |
|---|---|
| Lumina | MIT |
| FFmpeg | GPL v2+ |
| libx264 | GPL v2 |
| libx265 | GPL v2 |

FFmpeg source code is available at [ffmpeg.org](https://ffmpeg.org).
Full GPL v2 license text: [gnu.org/licenses/gpl-2.0.html](https://www.gnu.org/licenses/gpl-2.0.html)

> Because Lumina includes GPL-licensed FFmpeg, it **cannot be distributed on the Mac App Store**.

---

## Architecture

```
lumina/
├── App/                    # AppDelegate, MainWindowController, entitlements
├── Core/
│   ├── Database/           # GRDB repositories (MediaItem, Playlist)
│   └── Models/             # MediaItem, Playlist, PlaybackState
├── Features/
│   ├── Library/            # ContentView, LibraryViewModel, MediaGrid
│   ├── VideoPlayer/        # VideoPlayerView, VideoPlayerViewModel
│   ├── AudioPlayer/        # AudioPlayerView, AudioPlayerViewModel
│   ├── PhotoViewer/        # PhotoViewerView, PhotoViewerViewModel
│   └── Onboarding/         # OnboardingView
├── Services/
│   ├── FFmpegBridge.swift  # MKV/AVI transcoding via bundled ffmpeg
│   ├── ImportService.swift # Folder scanning and media import
│   ├── ThumbnailService.swift
│   ├── AudioEngineService.swift  # AVAudioEngine + EQ
│   ├── BookmarkService.swift
│   └── FolderWatcher.swift
└── Shared/
    ├── Components/
    └── Extensions/
```

---

## Contributing

Pull requests are welcome. For major changes, open an issue first to discuss what you'd like to change.

```bash
# Fork the repo, then:
git checkout -b feature/your-feature
git commit -m "feat: add your feature"
git push origin feature/your-feature
# Open a Pull Request
```

---

## Roadmap

- [ ] iCloud sync
- [ ] Chromecast / AirPlay support
- [ ] Batch export / convert
- [ ] Smart playlists
- [ ] Notarization (requires replacing FFmpeg with non-GPL alternative)

---

## License

Lumina is released under the [MIT License](LICENSE).

FFmpeg is licensed under the [GPL v2](https://www.gnu.org/licenses/gpl-2.0.html).

---

<div align="center">

Built as part of **#30AppsIn30Days** · [@likhith1542](https://twitter.com/likhith1542)

</div>
