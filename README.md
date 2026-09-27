# AppLoomaRTC (iOS)

AppLooma RTC iOS SDK — real-time voice, video, live streaming and audio rooms by AppLooma LLC.

## Install (Swift Package Manager)

Xcode → File → Add Package Dependencies →
`https://github.com/AppLooma-RTC/iOS-SDK`

This monorepo directory is the source of truth; the public Swift package is
mirrored to that repository and tagged per release.

Add to `Info.plist`:
- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`

Tag the package at `0.5.1` or newer. The `AppLoomaUIKit` target (drop-in live
streaming, voice room and call screens) ships in the same package.

To keep audio running while the app is in the background, enable the
**Audio, AirPlay, and Picture in Picture** background mode. Bluetooth headsets
need no extra key: a connected headset is preferred, then wired, then the
loudspeaker or earpiece; `engine.audioRoutes`, `engine.setAudioRoute(_:)` and
the delegate's `audioRouteChanged` drive an in-call route picker.

## Quickstart

```swift
import AppLoomaRTC

class CallViewController: UIViewController, AppEngineDelegate {
    var engine: AppEngine!

    override func viewDidLoad() {
        super.viewDidLoad()
        engine = AppEngine.create(appId: "YOUR_APP_ID", delegate: self)

        Task {
            // Get { token, wsUrl } from YOUR server, which calls
            // POST https://api.applooma.dev/v1/token with your API key/secret.
            try await engine.joinChannel(
                token: token,
                wsUrl: wsUrl,
                options: AppJoinOptions(role: .host, camera: true)
            )
        }
    }

    func appEngine(_ engine: AppEngine, trackSubscribedFor user: AppRemoteUser) {
        remoteVideoView.attach(user: user)   // AppVideoView
    }
}
```

Controls:

```swift
try await engine.enableCamera(false)
try await engine.enableMicrophone(false)
try await engine.sendData(Data("hello".utf8))
await engine.leaveChannel()
```

## Video quality

1080p at 4 Mbps by default (720p at 2.2 Mbps, 1440p preset at 5 Mbps). Choose what
the encoder gives up first with `degradation`, cap it with `maxBitrate`, and watch the
delegate's `videoQualityChanged`. `.h265` is hardware-encoded on every iPhone since
the 7.

```swift
let engine = AppEngine.create(appId: "YOUR_APP_ID", delegate: self, options: AppEngineOptions(
    video: AppVideoConfig(height: 1080, fps: 30, maxBitrate: 4_000_000, degradation: .keepResolution)
))
```

## What it depends on

`AppLoomaCore`, the media transport layer, resolved automatically by Swift
Package Manager. Nothing else.

## Roles

`host` (admin + publish) · `cohost` (publish) · `audience` (view only)

Docs: https://docs.applooma.dev/sdk/ios
