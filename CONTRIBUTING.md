# Contributing to Tidewall

Thanks for helping out!

## Getting started

```bash
swift test                    # must pass before a PR
Scripts/build-app.sh debug    # builds build/Tidewall.app for your Mac
open build/Tidewall.app
```

You need Xcode 26 or later, since the standalone Command Line Tools lack SwiftUI's macros. The build script uses `/Applications/Xcode.app` automatically. Set `DEVELOPER_DIR` to use a different Xcode.

## Guidelines

- **Match the surrounding code.** The engine is AppKit and AVFoundation, the UI is SwiftUI with `@Observable` models, and everything touching UI or players is `@MainActor`.
- **Mind the battery.** Wallpapers run all day. Avoid per-frame work: filters run live only while a look is being edited, and are otherwise baked into a playback copy. Anything that polls needs a very good reason.
- **Measure performance changes.** Quit Tidewall, then compare before and after with `Scripts/benchmark.sh`. It plays scenarios in a real desktop window and reports GPU use plus the CPU used by Tidewall, WindowServer, the video decoder and coreaudiod. For example:

  ```bash
  BENCH_ROUNDS=3 Scripts/benchmark.sh "idle||" "plain|Resources/Aurora.mov|" "filtered|Resources/Aurora.mov|blur=12,saturation=1.3"
  ```
- **Keep the library format compatible.** New settings must decode with a default when missing. `KeyedDecodingContainer.decode(_:default:)` exists for this. Add a test in `Tests/TidewallTests`.
- **Test what you change.** Add or update tests for engine and model changes. For UI changes, describe what you checked by hand, and include a screenshot in the PR.

## Reporting bugs

Include your macOS version, your Mac (Apple silicon or Intel), your display setup, and, if possible, the video that misbehaves or its codec and resolution.

By contributing, you agree that your contributions are licensed under the GPL-3.0 license, the same as the project.
