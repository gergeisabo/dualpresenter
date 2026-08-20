# DualPresenter

A minimal iOS presentation recorder: one app, two ways to capture. **Dual Cam** mode (RØDE Capture style) records the back camera on the content and your face on the front camera at the same time, then glues them into one picture-in-picture video. **Screen + Face** mode (Zoom style) records whatever app you present in while a small face bubble stays on screen. One record button, one share button, nothing else.

## Status

M1: complete — Dual Cam mode records front+back, composites to one video; build + 9 tests green on Xcode 26.3

## Build

On the Mac (repository at `your project folder`):

```sh
/tmp/xcodegen-bin/xcodegen/bin/xcodegen generate
xcodebuild -project DualPresenter.xcodeproj -scheme DualPresenter -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

## Requirements

- Xcode 26.3
- iOS 17+
- A12+ device for camera features
