<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.webp?v=2"><img src="docs/images/hero.webp?v=2" alt="Shiftio: a file conversion ring, a pop-up ring with a music player and a video editor" width="100%"></picture>
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-111?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-arm64-444">
  <img alt="11 languages" src="https://img.shields.io/badge/languages-11-2f7">
</p>

<p align="center">
  <b>Pick up a file. Press Shift. Drop it on an action.</b><br>
  A menu bar app for macOS 26 that turns the pointer into a ring of file tools and system controls, drawn in Liquid Glass.
</p>

> [!NOTE]
> **Beta, and a vibe-coded project.** Shiftio is built with AI: the code is written by Claude Code under my direction, and I steer it by running the app and checking the result. It is early software (version 0.1.0 beta): expect rough edges, and please open an issue when something breaks.

---

**Shiftio** lives in the menu bar. Drag any file (or several) and press **Shift**: a ring of actions opens under the pointer. Convert it, compress it, trim it, crop it, annotate it, transcribe it. Drop the file on a tile and the result is saved next to the original. Hold **⌥⇧** with nothing in your hand and a second ring opens with system controls, your apps, folders and Telegram chats.

Everything runs on the Mac, offline. No account, no Accessibility permission, no notifications.

## Install

1. Download **Shiftio.dmg** (or **Shiftio.zip**) from the [latest release](../../releases/latest) and drag Shiftio to Applications.
2. The beta is **not notarized** by Apple yet, so macOS may say the app is damaged or from an unidentified developer. Clear the quarantine flag once and open it again:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Shiftio.app
   ```
3. Requires macOS 26 and an Apple silicon Mac. The MP3 encoder and the speech model are downloaded on first launch.

## Contents

[File ring](#the-file-ring) · [Pop-up ring](#the-pop-up-ring) · [Photo editor](#photo-editor) · [Quick tools](#quick-tools) · [Video editor](#video-editor) · [Convert and compress](#convert-compress-and-more) · [Looks and themes](#looks-and-themes) · [Settings](#settings-and-first-launch) · [Privacy](#privacy-and-technology)

## The file ring

Drag a file and press the trigger key (Shift by default). The ring shows what fits the file: images, PDFs, documents, audio, video, or several files at once. Press the key again to flip to the next ring (Convert, Edit, Optimize, Tools). Drop the file on a tile to run it; drop it in the empty centre to cancel.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/ring-images-dark.webp"><img src="docs/images/ring-images.webp" width="49%" alt="Convert ring for images"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/ring-edit-dark.webp"><img src="docs/images/ring-edit.webp" width="49%" alt="Edit ring for images"></picture>
</p>

- **Rings that adapt:** a different set for images, PDFs, documents, audio, video, and for several files at once.
- **Recent tools first:** the tools you used last and most often float to the front.
- **Fully configurable:** reorder tiles, rename them, give a tile your own icon or emoji, add **Shortcuts** or apps, add or remove whole rings.
- **Touch Bar support:** on Macs with a Touch Bar the open ring is mirrored there, tinted with your accent. Tap a tile to run the action, or the ring button to flip to the next ring; the Touch Bar follows the ring as you switch. No setup needed.

<p align="center">
  <img src="docs/images/touchbar.png" width="60%" alt="The Convert ring mirrored on the Touch Bar">
</p>

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-rings-image-dark.webp"><img src="docs/images/settings-rings-image.webp" width="60%" alt="Ring editor"></picture>
</p>

## The pop-up ring

Hold **⌥⇧** (about 0.3 s), point at a tile and let go. No file needed.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/popup-dark.webp"><img src="docs/images/popup.webp" width="49%" alt="System controls ring"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/popup-apps-dark.webp"><img src="docs/images/popup-apps.webp" width="49%" alt="Pinned apps and Telegram chats"></picture>
</p>

- **System controls:** Wi-Fi, Bluetooth, appearance (auto, light, dark), keyboard backlight, Keep Awake (15 minutes, 1 hour, 4 hours, until off), System Settings, folders. Tiles with options open a second ring.
- **Apps, folders and Telegram chats** that you pin yourself. Chat photos are read from Telegram or chosen by drag and drop.
- **Recent and frequent apps,** counted by Shiftio itself, as a separate tile or merged with your pins.
- **Screenshot and screen recording** tiles (area, window or screen) that open the result in Quick Look. Add them in the ring editor.
- **Music player** above the ring for Apple Music and Spotify: cover, play controls, a seek bar, synced lyrics and the queue.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/popup-player-dark.webp"><img src="docs/images/popup-player.webp" width="49%" alt="Music player above the ring"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/popup-recent-dark.webp"><img src="docs/images/popup-recent.webp" width="49%" alt="Recent apps"></picture>
</p>

## Photo editor

A full non-destructive editor for images. Save as a copy or replace the original (the old file goes to the Trash).

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/editor-filters-dark.webp"><img src="docs/images/editor-filters.webp" width="49%" alt="Photo editor: filters"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/editor-markup-dark.webp"><img src="docs/images/editor-markup.webp" width="49%" alt="Photo editor: markup"></picture>
</p>

- **Adjust:** exposure, brightness, contrast, highlights, shadows, saturation, vibrance, warmth, tint, histogram, auto enhance.
- **Filters:** one-click looks (Vivid, Dramatic, Mono, Silvertone, Noir, Chrome, Fade, Instant, Process, Transfer, Sepia).
- **Crop and rotate:** aspect ratios, straighten, rotate and flip.
- **Markup:** arrows, rectangles, ellipses, pen, highlighter and text.
- **Compare** with the original (hold the button), zoom, full undo and redo.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/editor-crop-dark.webp"><img src="docs/images/editor-crop.webp" width="80%" alt="Photo editor: crop"></picture>
</p>

## Quick tools

Small focused windows that finish in one step.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tool-add-bg-dark.webp"><img src="docs/images/tool-add-bg.webp" width="24%" alt="Add a background"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tool-annotate-dark.webp"><img src="docs/images/tool-annotate.webp" width="24%" alt="Annotate"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tool-redact-dark.webp"><img src="docs/images/tool-redact.webp" width="24%" alt="Redact"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tool-compress-dark.webp"><img src="docs/images/tool-compress.webp" width="24%" alt="Compress"></picture>
</p>

- **Crop:** pixel sizes or aspect ratios, with a live preview.
- **Add a background:** gradients, colours, padding, rounded corners, shadow and ratio, perfect for screenshots.
- **Annotate:** the markup tools without the full editor.
- **Redact:** black out or pixelate; *Find Text* detects text on the image for you.
- **Remove background:** cut out the subject with on-device Vision masks.
- **Get Info:** size, dates, EXIF, location on a map, codec and bitrate for video.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tool-info-dark.webp"><img src="docs/images/tool-info.webp" width="32%" alt="Get Info"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tool-info-video-dark.webp"><img src="docs/images/tool-info-video.webp" width="32%" alt="Get Info for video"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tool-compress-video-dark.webp"><img src="docs/images/tool-compress-video.webp" width="32%" alt="Compress video"></picture>
</p>

## Video editor

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/video-clip-dark.webp"><img src="docs/images/video-clip.webp" width="24%" alt="Video editor: clip"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/video-picture-dark.webp"><img src="docs/images/video-picture.webp" width="24%" alt="Video editor: picture"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/video-sound-dark.webp"><img src="docs/images/video-sound.webp" width="24%" alt="Video editor: sound"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/video-save-dark.webp"><img src="docs/images/video-save.webp" width="24%" alt="Video editor: save as"></picture>
</p>

- **Clip:** trim, cut out, split, join clips, speed (0.5× to 2×), fade in and out, play backwards.
- **Picture:** crop to a ratio, rotate, flip.
- **Sound:** volume, normalize, reduce noise, replace the soundtrack, or mute.
- **Overlay:** text or image watermark, blur or pixelate a region, burn in subtitles or export an SRT file.
- **Save as:** MP4, HEVC, ProRes or GIF, with presets and a size limit for messengers (8, 10, 16, 25, 50 MB).

## Convert, compress and more

Everything runs on the Mac, offline.

| | |
|---|---|
| **Convert images** | JPG, PNG, HEIC, TIFF, GIF, BMP |
| **PDF** | pages to images, merge PDFs, compress |
| **Documents** | DOCX, RTF, HTML, TXT |
| **Audio** | MP3, M4A, WAV, AIFF, FLAC |
| **Video** | MP4, HEVC, ProRes, GIF |
| **Compress** | images, PDFs, audio and video, with a live size estimate and quality, size or bitrate limits |
| **Text from speech** | transcripts and SRT subtitles with Apple's on-device speech model |
| **Files** | ZIP, strip metadata (camera, location), Get Info |
| **Batches** | several files at once, results saved next to each original |

## Looks and themes

Rings, the player and the editor windows are made of glass that you can tune. Pick a **theme** (follow system, light or dark), a **material** (Follow macOS Liquid Glass, Clear, Frosted or Solid), how tinted the glass is, how heavy the blur is, and an **accent colour** (system accent, your own colour, or neutral gray). Reduce Transparency and Increase Contrast are respected.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/look-dark.webp"><img src="docs/images/look.webp" width="100%" alt="Glass styles: Follow macOS, Clear, Frosted and Solid on light, dark and gradient backgrounds"></picture>
</p>

<p align="center"><sub>Columns: Follow macOS · Clear · Frosted · Solid. Rows: light, dark, gradient.</sub></p>

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-appearance-dark.webp"><img src="docs/images/settings-appearance.webp" width="32%" alt="Settings: appearance"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/settings-general-dark.webp"><img src="docs/images/settings-general.webp" width="32%" alt="Settings: general"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/menu-dark.webp"><img src="docs/images/menu.webp" width="32%" alt="Menu bar popover"></picture>
</p>

## Settings and first launch

A short interactive tour teaches both rings by letting you press the real keys, asks for permissions only when you press Allow, and offers the settings people change first.

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tour-0-dark.webp"><img src="docs/images/tour-0.webp" width="24%" alt="Tour: file ring"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tour-1-dark.webp"><img src="docs/images/tour-1.webp" width="24%" alt="Tour: pop-up ring"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tour-2-dark.webp"><img src="docs/images/tour-2.webp" width="24%" alt="Tour: permissions"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/images/tour-3-dark.webp"><img src="docs/images/tour-3.webp" width="24%" alt="Tour: make it yours"></picture>
</p>

- **General:** enable, open at login, language, trigger key (Shift or another modifier), reveal results in Finder, recent tools first, pop-up ring and its hold delay, player on or off.
- **Rings:** edit every ring for every kind of file, plus the pop-up ring.
- **Appearance:** theme, accent, glass material, ring size, icons and labels.
- **Menu bar popover:** on/off switch, recent results with errors and **Clear**, Settings and Quit.
- **11 languages:** English, Ukrainian, Spanish, Portuguese, Japanese, Simplified Chinese, Korean, French, Czech, Italian and Indonesian. Follows the system language or the one you pick.

## Privacy and technology

- **No Accessibility permission.** Nothing asks for input monitoring.
- **Permissions only on request.** Opening a ring never raises a system dialog; Bluetooth, Automation (Music, Spotify, System Events) and Files & Folders are requested only when you press Allow.
- **On-device processing.** Vision (OCR, subject masks), Speech, Core Image, AVFoundation and PDFKit; nothing is uploaded and there is no account.
- **First-launch components.** The MP3 encoder is downloaded as a checksum-verified Homebrew bottle, and the speech model on demand, so the app stays small.
- **Native.** SwiftUI and Liquid Glass, Apple silicon, 11 languages.

## Author

Dmytro Demchuk ([@mewwtwo](https://github.com/mewwtwo)).
