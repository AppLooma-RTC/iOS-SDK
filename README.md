# AppLoomaRTC — iOS SDK

Real-time voice, video, live streaming and audio rooms for iOS, by
[AppLooma LLC](https://applooma.dev).

Full documentation: **https://docs.applooma.dev/sdk/ios**

## Requirements

| | |
|---|---|
| Platforms | iOS 14+, macOS 11+ |
| Swift tools | 5.9+ |
| Account | An App ID and key pair from the [console](https://applooma.dev/dashboard) |

## Install

In Xcode: **File → Add Package Dependencies…** and enter

```
https://github.com/apploomadev/iOS-SDK
```

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/apploomadev/iOS-SDK", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "AppLoomaRTC", package: "iOS-SDK")
    ])
]
```

Add to `Info.plist`, or the app terminates the first time it uses a device:

- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`

## Quickstart

Tokens come from **your** server. Your API secret must never ship inside an app —
anyone who extracts it can issue unlimited tokens on your account.

```swift
import AppLoomaRTC

final class CallViewController: UIViewController, AppEngineDelegate {
    private var engine: AppEngine!

    override func viewDidLoad() {
        super.viewDidLoad()
        engine = AppEngine.create(appId: "YOUR_APP_ID", delegate: self)

        Task {
            // Your own endpoint, which calls POST https://api.applooma.dev/v1/token
            // server-side with your API key and secret.
            let session = try await api.rtcToken(channel: "lobby")

            try await engine.joinChannel(
                token: session.token,
                wsUrl: session.wsUrl,
                options: AppJoinOptions(role: .host, camera: true)
            )
        }
    }

    // A participant is announced before their camera arrives, so render here
    // rather than in userJoined — otherwise the tile stays black.
    func appEngine(_ engine: AppEngine, trackSubscribedFor user: AppRemoteUser) {
        remoteVideoView.attach(user: user)
    }

    func appEngine(_ engine: AppEngine, userJoined user: AppRemoteUser) {
        addTile(for: user)
    }

    func appEngine(_ engine: AppEngine, userLeft user: AppRemoteUser) {
        removeTile(for: user)
    }
}
```

### Controls

```swift
try await engine.enableCamera(false)
try await engine.enableMicrophone(false)
try await engine.sendData(Data("hello".utf8))
await engine.leaveChannel()
```

## Roles

The role is fixed by the token your server issues, not by the client.

| Role | Can publish | Can subscribe | Can administer the channel |
|---|---|---|---|
| `host` | yes | yes | yes |
| `cohost` | yes | yes | no |
| `audience` | no | yes | no |

Use `audience` for viewers of a live stream. An audience token cannot publish,
which is what keeps a large broadcast cheap and stable.

## Support

- Documentation — https://docs.applooma.dev
- Email — support@applooma.dev

## Licence

MIT. See [LICENSE](LICENSE).
