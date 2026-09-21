# Changelog

## Unreleased

**Pulse**, a live audio visualizer wallpaper:
- **Hears your Mac:** it listens to the system audio mix through a Core Audio process tap. The audio is analyzed in memory and never recorded.
- **The picture:** a ring spectrum, a bass-driven core, beat shockwaves, and particles that speed up with loudness, rendered on the GPU.
- **Options:** five color schemes, plus sensitivity, motion and quality settings, in a live editor.
- **Easy on power:** it listens only while it's visible and something is playing, drops to 20 fps when idle, and pauses when covered.
- **Arrives automatically** in existing libraries.

Battery-reactive wallpapers:
- A wallpaper can hold one video per battery state, and cross-fades to the matching one as the charge changes. It uses the same thresholds as the Lantern battery gauge, so the two stay in sync.
- New `.tidewall` package format (a folder with a `wallpaper.json` manifest) for importing such sets.
- `Scripts/make-lantern.swift` renders a set that matches Lantern: lit from the emblem's exact position, in each corps' palette, with its particle behavior.

New built-in wallpaper, **Cool Chicken**: a chicken in sunglasses struts through a synthwave sunset, rendered procedurally in 4K60 as a seamless 12-second loop.
- Existing libraries receive new built-ins automatically.
- The library's **+** menu (and **File → Add Built-in Wallpaper**) re-adds any built-in.

Lower CPU and GPU use at the same quality:

- Color adjustments are baked into an HEVC playback copy a few seconds after editing stops, so the desktop no longer filters every frame. A filtered 4K60 wallpaper went from 27% GPU / 29% CPU to 0.7% / 2.3% (M5 Max). Copies are visually lossless (51–56 dB PSNR).
- Videos much larger than your displays are downscaled in the copy, and sources your Mac can't decode in hardware are re-encoded.
- Wallpapers pause when windows cover 95% of a display's desktop. Previously they paused only at 100%, which the translucent menu bar prevented.
- Muted wallpapers no longer keep the audio pipeline running.
- Player swaps (for example to a finished copy) no longer flash black; the new picture takes over once its first frame is ready.
- Settings → Performance: an Optimize playback toggle, plus the size of the playback copies and a button to delete them.
- `Scripts/benchmark.sh` measures the cost of playback scenarios.

## 1.0.0

First release.

- Import videos (MP4, MOV, M4V) and animated images (GIF, PNG, WebP, HEICS), which are converted to H.264.
- Loop editor with filmstrip trimming, framing, speed, color adjustments and audio. Edits apply live.
- Per-display wallpapers with a display arrangement map.
- Menu bar switcher with pause/resume.
- Automatic pausing when the desktop is hidden, locked or asleep, and optionally in Low Power Mode or on battery.
- Optional matching macOS desktop picture, open at login, optional Dock icon.
- Bundled seamless "Aurora" sample.
