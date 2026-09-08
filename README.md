# AppLoomaRTC (iOS)

AppLooma RTC iOS SDK — real-time voice, video, live streaming and audio rooms by AppLooma LLC.

## Install (Swift Package Manager)

Xcode → File → Add Package Dependencies →
`https://github.com/applooma/applooma-rtc-ios`

Add to `Info.plist`:
- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`

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

## Roles

`host` (admin + publish) · `cohost` (publish) · `audience` (view only)

Docs: https://applooma.dev/dashboard/docs
