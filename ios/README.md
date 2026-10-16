# VR Player for iPhone

A native, touch-controlled SBS 180 movie player. AVFoundation decodes the original video and plays its audio. Metal projects one eye into one full-screen view. The app never records or re-encodes local video.

## Use

Choose **Photos**, **Files**, or **Plex**. Drag with one finger to look around. Pinch to zoom. Tap to show or hide controls. Controls disappear after three seconds during playback. System gestures can briefly reveal iOS overlays.

The settings menu selects the left or right eye, standard or fisheye 180-degree projection, resets the view, and shows playback diagnostics. Manual touch controls own the camera; the app does not use face tracking or device motion.

Photos imports use Apple's picker and preserve the current video representation. Imports stay in the app's Documents/Movies folder until deleted from Recents. Files use persistent bookmarks without copying the movie. A file provider may require renewed access when a file moves or its authorization expires. Swipe a Recent entry to delete it; deleting a Photos import removes the app's copy, not the Photos original.

Plex uses account sign-in, Keychain token storage, server discovery, library browsing, title search, and pagination. Direct Play always comes first. If Apple cannot play the original file, the app requests a container conversion and checks that Plex copies the video. Any video conversion requires a separate confirmation. Plex server capabilities and account restrictions still apply. The app saves its own playback position and view; it does not modify Plex watch history.

## Build and install

Use Xcode, XcodeGen, and the configured Apple development team. The app targets iOS 18 or later. The project uses no third-party runtime packages.

```sh
./ios/scripts/build_and_run.sh
```

The script detects one paired iPhone, builds a Release version, signs it, installs it, and launches it. Set `VR_DEVICE_ID` when multiple iPhones appear. Apple requires Developer Mode for this development installation. The script keeps one current app in `ios/dist/VRPlayer.app` and removes its build cache after installation.

The generated `VRPlayer.xcodeproj` comes from `project.yml`. Regenerate it with `xcodegen generate --spec ios/project.yml` after changing the specification.

## Tests

```sh
xcodebuild -project ios/VRPlayer.xcodeproj -scheme VRPlayer \
  -destination 'platform=iOS Simulator,name=VR Player iPhone 16 Pro' \
  -derivedDataPath ios/simulator-build CODE_SIGNING_ALLOWED=NO test
```

The named simulator must exist before running that command. Remove temporary simulators and `ios/simulator-build` after testing.

Unit tests cover eye coordinates, camera bounds, zoom limits, saved playback state, Plex response parsing, conversion safeguards, and URL encoding. The repository contains no automated UI tests.

## Rendering and extensions

`PlaybackEngine` owns AVPlayer, loading, seeking, state persistence, audio, and lifecycle. `VideoRenderer` owns decoded-frame presentation. It requests linear BT.2020 half-float pixels and presents through an extended-range Metal layer. The shader applies source orientation and eye selection, then draws the 180-degree projection. It does not resize the decoded source or introduce an encode/decode loop.

`ViewState` owns camera math. `PlaybackAction` routes playback and viewing commands. New buttons call these actions; movie sources and the renderer do not depend on UIKit controls. `PlexService` handles Plex requests and conversion decisions.

The display link follows screen refresh while the renderer draws only for new frames or camera changes. Diagnostics record frame counts and thermal state without movie names, server URLs, or access tokens. The playback target is up to 4K. Real-device measurements determine supported frame rates; simulator timings do not establish phone performance.

The existing website remains independent and unchanged.
