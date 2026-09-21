# Changelog

## Unreleased

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
