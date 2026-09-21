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
- **Mind the battery.** Wallpapers run all day. Avoid per-frame work on the main thread. Keep video on the hardware decode path, so filters run only while an adjustment is active. Anything that polls needs a very good reason.
- **Keep the library format compatible.** New settings must decode with a default when missing. `KeyedDecodingContainer.decode(_:default:)` exists for this. Add a test in `Tests/TidewallTests`.
- **Test what you change.** Add or update tests for engine and model changes. For UI changes, describe what you checked by hand, and include a screenshot in the PR.

## Reporting bugs

Include your macOS version, your Mac (Apple silicon or Intel), your display setup, and, if possible, the video that misbehaves or its codec and resolution.

By contributing, you agree that your contributions are licensed under the GPL-3.0 license, the same as the project.
