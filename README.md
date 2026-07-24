# LioRTC (iOS)

Lio Live iOS SDK — real-time voice, video, live streaming and audio rooms by AppLooma LLC.

## Install (Swift Package Manager)

Xcode → File → Add Package Dependencies →
`https://github.com/applooma/lio-rtc-ios`

Add to `Info.plist`:
- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`

## Quickstart

```swift
import LioRTC

class CallViewController: UIViewController, LioEngineDelegate {
    var engine: LioEngine!

    override func viewDidLoad() {
        super.viewDidLoad()
        engine = LioEngine.create(appId: "YOUR_APP_ID", delegate: self)

        Task {
            // Get { token, wsUrl } from YOUR server, which calls
            // POST https://api.applooma.dev/v1/token with your API key/secret.
            try await engine.joinChannel(
                token: token,
                wsUrl: wsUrl,
                options: LioJoinOptions(role: .host, camera: true)
            )
        }
    }

    func lioEngine(_ engine: LioEngine, trackSubscribedFor user: LioRemoteUser) {
        remoteVideoView.attach(user: user)   // LioVideoView
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

## Roles

`host` (admin + publish) · `cohost` (publish) · `audience` (view only)

Docs: https://applooma.dev/dashboard/docs
