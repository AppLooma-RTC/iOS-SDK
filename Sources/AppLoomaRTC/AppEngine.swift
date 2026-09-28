// AppLooma RTC iOS SDK — main entry point.
// © AppLooma LLC
//
//   let engine = AppEngine.create(appId: "YOUR_APP_ID", delegate: self)
//   try await engine.joinChannel(token: token, wsUrl: wsUrl,
//                                options: AppJoinOptions(role: .host, camera: true))

import Foundation
import AppLoomaCore
#if os(iOS)
import AVFoundation
import UIKit
import CoreMedia
import VideoToolbox
#endif

/// Roles supported by AppLooma RTC channels.
public enum AppRole: String, Sendable {
    case host, cohost, audience
}

/// Connection lifecycle states.
public enum AppConnectionState: Sendable {
    case connecting, connected, reconnecting, disconnected
}

/// Milestones on the way to seeing a remote picture, each with elapsed
/// milliseconds since `joinChannel`.
public enum AppConnectionStage: Sendable {
    case connected, firstRemoteVideoFrame
}

/// How the engine treats audio for the whole session. Pick once, at create time.
///
/// `.call` is the phone's communication path: echo cancellation tuned for
/// speech, the earpiece by default. `.media` keeps the loudspeaker and
/// music-grade bandwidth while still running the session in `playAndRecord`
/// + `videoChat`, so the echo canceller stays engaged — voice rooms with music
/// and live streams sound better on `.media`; a private call belongs on `.call`.
public enum AppAudioScenario: Sendable {
    case call, media
}

/// Where the call's audio is going. A Bluetooth headset (AirPods, a car kit),
/// when connected, wins by default; then wired headphones; then the
/// loudspeaker (`.media`) or the earpiece (`.call`). See `AppEngine.setAudioRoute`.
public enum AppAudioRoute: Sendable {
    case bluetooth, wiredHeadset, earpiece, speaker
}

/// Which codec your camera is published with.
///
/// `.auto` (default) publishes H.264 — hardware-encoded on every iPhone — with
/// a VP8 backup layer, so a viewer that cannot decode the H.264 stream still
/// gets a picture. Force one only for a known fleet.
public enum AppVideoCodec: Sendable {
    case auto, vp8, h264
    /// H.265 — hardware-encoded on every iPhone since the 7, about 30 % fewer
    /// bits than H.264 for the same picture. Opt-in; the VP8 backup layer still
    /// rides along for viewers that cannot decode it.
    case h265
    /// AV1 is not available on iOS: no iPhone encodes it in hardware and the
    /// software encoder cannot keep up at camera sizes. Falls back to `.auto`
    /// with a warning; kept so one config compiles on every platform.
    case av1
}

/// What the encoder gives up first when the network or the CPU cannot carry
/// the full picture.
///
/// `.auto` (default) is the engine's choice for a camera — frame rate is kept
/// and resolution drops, which looks smoothest in a call. `.keepResolution`
/// keeps the picture sharp and drops frames instead — for a 1080p broadcast
/// where crispness is the product. `.keepFramerate` keeps motion smooth and
/// lets the picture soften. `.balanced` gives up a little of each.
public enum AppVideoDegradation: Sendable {
    case auto, keepResolution, keepFramerate, balanced
}

/// Which of your simulcast layers the numbers in `AppVideoQualityInfo` describe.
public enum AppVideoLayer: Sendable {
    case high, medium, low
}

/// Why the encoder is not sending the full picture, when it is not.
public enum AppVideoQualityReason: Sendable {
    case bandwidth, cpu, none
}

/// What your own camera is actually sending right now — the top layer that
/// carries frames, its size, rate and bitrate, and why it is not the full
/// picture if it is not. Delivered on `appEngine(_:videoQualityChanged:)`
/// whenever any of it changes while the camera is on.
public struct AppVideoQualityInfo: Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let bitrateKbps: Int
    public let layer: AppVideoLayer
    public let reason: AppVideoQualityReason
}

/// How the SDK tunes your camera when you leave the details to it.
///
/// `.stableHd` (default) holds one steady HD picture: a single layer,
/// resolution kept under pressure (frame rate gives way first) and receivers
/// pinned to the full picture. 1080p30 at 3.5 Mbps (every iPhone encodes in
/// hardware).
///
/// `.ultraHd4k` is the premium mode: 2160p30, one layer, resolution kept,
/// H.265 at 16 Mbps. Both ends need a strong network (20 Mbps or more each way
/// recommended) and the phone runs warmer. See `AppEngine.isUltraHdSupported()`.
///
/// `.adaptive` is the earlier behaviour: three layers, receivers switch layers
/// by view size and network, resolution may drop to keep motion smooth.
///
/// Any field you set explicitly on `AppVideoConfig` wins over the mode.
public enum AppVideoMode: Sendable {
    case stableHd, ultraHd4k, adaptive
}

/// Capture and encode settings for your own camera.
///
/// `mode` picks sensible values for everything below; see `AppVideoMode`.
/// Fields left at their default follow the mode, fields you set win.
///
/// `maxBitrate` is in **bits per second** — `1_900_000` for 1.9 Mbps. A value
/// under 10 000 is almost certainly kbps by mistake and is logged as a warning.
/// `height` must be one of 360 / 540 / 720 / 1080 / 1440 / 2160; anything else
/// snaps to the nearest preset (also logged). 0 = chosen by the mode.
public struct AppVideoConfig: Sendable {
    /// 360, 540, 720, 1080, 1440 or 2160 — the short edge of a 16:9 frame. 0 = chosen by `mode`.
    public var height: Int
    public var fps: Int
    /// Cap on the encoder's bitrate in bits per second; 0 = chosen by `mode`
    /// (3.5 Mbps at 1080p for `.stableHd`, 16 Mbps H.265 / 25 Mbps otherwise
    /// for `.ultraHd4k`; in `.adaptive` 5 Mbps at 1440p, 4 Mbps at 1080p,
    /// 2.2 Mbps at 720p, the preset default below that).
    public var maxBitrate: Int
    /// Three layers so weak links still get a picture; false = one layer only.
    /// nil = chosen by `mode` (on in `.adaptive`, off otherwise).
    public var simulcast: Bool?
    public var codec: AppVideoCodec
    /// What to give up first under pressure. See `AppVideoDegradation`.
    /// `.auto` = chosen by `mode` (`.keepResolution` in `.stableHd` and `.ultraHd4k`).
    public var degradation: AppVideoDegradation
    /// The overall tuning; see `AppVideoMode`.
    public var mode: AppVideoMode
    /// Floor on the encoder's bitrate in bits per second; 0 = engine default.
    /// Reserved: the engine exposes no per-sender minimum on iOS today, so the
    /// value is kept but does not change what is sent.
    public var minBitrate: Int

    public init(height: Int = 0, fps: Int = 30, maxBitrate: Int = 0, simulcast: Bool? = nil, codec: AppVideoCodec = .auto,
                degradation: AppVideoDegradation = .auto, minBitrate: Int = 0, mode: AppVideoMode = .stableHd) {
        self.mode = mode
        self.height = height
        self.fps = fps
        self.maxBitrate = maxBitrate
        self.simulcast = simulcast
        self.codec = codec
        self.degradation = degradation
        self.minBitrate = minBitrate
    }
}

/// Microphone processing. Each stage can be switched independently; all on by default.
public struct AppAudioOptions: Sendable {
    public var echoCancellation: Bool
    public var noiseSuppression: Bool
    public var autoGainControl: Bool
    /// Noise suppression mode, `.standard` by default. `noiseSuppression =
    /// false` also means `.off`. See `AppNoiseSuppression`.
    public var noiseSuppressionMode: AppNoiseSuppression

    public init(echoCancellation: Bool = true, noiseSuppression: Bool = true, autoGainControl: Bool = true,
                noiseSuppressionMode: AppNoiseSuppression = .standard) {
        self.echoCancellation = echoCancellation
        self.noiseSuppression = noiseSuppression
        self.autoGainControl = autoGainControl
        self.noiseSuppressionMode = noiseSuppressionMode
    }

    /// The mode in force once `noiseSuppression` and `noiseSuppressionMode` are combined.
    public var effectiveNoiseSuppression: AppNoiseSuppression { noiseSuppression ? noiseSuppressionMode : .off }
}

/// Noise suppression mode.
///
/// `.clear` ("Clear Voice") runs the microphone through Apple's voice
/// processing in the voice-chat mode in every audio scenario, which is also
/// what lets the user pick Voice Isolation from Control Center (see
/// `AppEngine.showMicrophoneModes()`). There is no on-device neural model in
/// the iOS SDK itself. `.off` turns the engine's suppressor off.
public enum AppNoiseSuppression: Sendable {
    case standard, clear, off
}

/// How much delay an audience member accepts for smoother playback; see
/// `AppEngineOptions.audienceLatency`.
public enum AppAudienceLatency: Sendable {
    case ultraLow, low, standard
}

/// One video codec this device can handle, from `AppEngine.getSupportedVideoCodecs()`.
/// `mime` is `"video/VP8"`, `"video/VP9"`, `"video/H264"` or `"video/H265"`.
public struct AppVideoCodecCapability: Sendable, Equatable {
    public let mime: String
    /// True when the codec runs on the device's hardware (VideoToolbox).
    public let hardware: Bool
    public let encoder: Bool
    public let decoder: Bool
}

/// Which server region the engine should prefer.
///
/// Preparation for multi-region: today every region connects to the same
/// server URL your token endpoint returns. The value is sent with the SDK's
/// anonymous device reports and logged on join.
public enum AppRegion: String, Sendable {
    case auto, bd, `in`, sa, sg, us
}

/// Engine-wide settings. All optional; the defaults are what most apps want.
public struct AppEngineOptions: Sendable {
    public var audioScenario: AppAudioScenario
    public var video: AppVideoConfig
    public var audio: AppAudioOptions
    /// Preferred server region; `.auto` by default. See `AppRegion`.
    public var region: AppRegion
    /// Remote diagnostics, default true. The SDK keeps its own recent log
    /// lines and a stats snapshot every 10 s in memory (never audio, video,
    /// messages or names) and uploads them, scrubbed, after a call that had a
    /// problem, when AppLooma support switched collection on for this device
    /// or project, or when you call `uploadDiagnostics(reason:)`. Kept 14
    /// days. `false` turns every upload off.
    public var remoteDiagnostics: Bool
    /// Cloud proxy for networks that block UDP or most ports; `.auto` by
    /// default. See `AppCloudProxy` and `proxyStateChanged`.
    public var cloudProxy: AppCloudProxy
    /// Audience latency tier, `.ultraLow` by default, applied only while the
    /// local user is audience. The iOS engine has no receive-side
    /// jitter-buffer control, so `.low` behaves like `.ultraLow`, and
    /// `.standard` only prefers lower video layers under congestion (it turns
    /// on `setRemoteSubscribeFallback(.videoLowQuality)` unless you set a
    /// fallback yourself).
    public var audienceLatency: AppAudienceLatency

    public init(audioScenario: AppAudioScenario = .call, video: AppVideoConfig = AppVideoConfig(), audio: AppAudioOptions = AppAudioOptions(),
                region: AppRegion = .auto, remoteDiagnostics: Bool = true, cloudProxy: AppCloudProxy = .auto,
                audienceLatency: AppAudienceLatency = .ultraLow) {
        self.audioScenario = audioScenario
        self.video = video
        self.audio = audio
        self.region = region
        self.remoteDiagnostics = remoteDiagnostics
        self.cloudProxy = cloudProxy
        self.audienceLatency = audienceLatency
    }
}

/// Cloud proxy for restrictive networks (office firewalls, UDP blocked).
/// `.auto` connects directly and, when that join fails with a connection or
/// network timeout, retries once through AppLooma's relay on TLS port 443.
/// `.forceTls443` always relays on TLS 443. `.off` never relays.
public enum AppCloudProxy: Sendable {
    case auto, forceTls443, off
}

/// `.direct`: media is not relayed (also after leaving). `.connecting`:
/// joining through the relay on TLS 443. `.connected`: in the channel
/// through the relay.
public enum AppProxyState: Sendable {
    case direct, connecting, connected
}

/// Network quality as estimated by the media server. Higher raw values are worse.
public enum AppNetworkQuality: Int, Sendable {
    case unknown, excellent, good, poor, lost
}

/// What the SDK gives up when the network cannot carry everything. `.none`
/// keeps everything (default); `.videoLowQuality` drops to the low layer
/// (receiving) or a lower bitrate (sending); `.audioOnly` drops video until
/// the network recovers. See `setRemoteSubscribeFallback(_:)` and
/// `setLocalPublishFallback(_:)`.
public enum AppFallbackOption: Sendable {
    case none, videoLowQuality, audioOnly
}

/// The result of `AppEngine.startNetworkTest(serverUrl:token:completion:)`.
public struct AppNetworkTestResult: Sendable {
    public let uplinkQuality: AppNetworkQuality
    public let downlinkQuality: AppNetworkQuality
    /// Round-trip time in milliseconds, -1 when unknown (always -1 on iOS today).
    public let rttMs: Int
    /// Incoming jitter in milliseconds, -1 when unknown (always -1 on iOS today).
    public let jitterMs: Int
    /// Fraction of outgoing packets lost, 0...1 (not measured on iOS today).
    public let uplinkLoss: Float
    /// Fraction of incoming packets lost, 0...1 (not measured on iOS today).
    public let downlinkLoss: Float
    /// Set when the test could not run or did not finish.
    public let error: String?
}

/// Per-remote-user media health, delivered every two seconds while joined.
///
/// A camera you are subscribed to reporting `videoFps` 0 is a stuck picture;
/// `videoFreezeCount` climbs each time it stalls; a climbing
/// `audioPacketsLost` is why one voice is breaking up while the others are fine.
public struct AppRemoteStats: Sendable {
    public let uid: String
    public let videoFps: Int
    public let videoWidth: Int
    public let videoHeight: Int
    public let videoFreezeCount: Int
    public let videoPacketsLost: Int
    public let audioPacketsLost: Int
    /// Audio jitter-buffer delay in milliseconds.
    public let audioJitterMs: Int
}

/// Options for joining a channel.
public struct AppJoinOptions: Sendable {
    public var role: AppRole
    /// Auto-enable camera on join (ignored for audience).
    public var camera: Bool
    /// Auto-enable microphone on join (ignored for audience).
    public var microphone: Bool

    public init(role: AppRole = .host, camera: Bool = false, microphone: Bool = true) {
        self.role = role
        self.camera = camera
        self.microphone = microphone
    }
}

/// A message sent to everyone in the channel.
///
/// Messages ride the same channel as the media, so they arrive with the same
/// latency and need no second connection. Nothing is stored: a message reaches
/// whoever is in the channel at the time.
public struct AppMessage {
    /// Unique to this message. Useful as a list id and for de-duplicating.
    public let id: String
    /// What was sent, when `sendMessage` was given text.
    public let text: String?
    /// What was sent, when it was given a dictionary.
    public let data: [String: Any]?
    /// Who sent it. Nil if it came from your own server.
    public let from: AppRemoteUser?
    /// The sender's clock, not ours — do not order messages by it alone.
    public let sentAt: Date
}

/// A remote user in the channel.
public final class AppRemoteUser {
    let participant: RemoteParticipant
    init(_ p: RemoteParticipant) { participant = p }

    public var uid: String { participant.identity?.stringValue ?? "" }
    public var displayName: String? { participant.name }
    public var isSpeaking: Bool { participant.isSpeaking }
    /// The user is publishing an unmuted microphone.
    public var audioEnabled: Bool { participant.isMicrophoneEnabled() }
    /// The user is publishing an unmuted camera.
    public var videoEnabled: Bool { participant.isCameraEnabled() }

    /// What this user is allowed to do, decided by the token their server minted.
    /// An `.audience` member can watch and send messages but cannot publish.
    public var role: AppRole {
        switch parsed()["role"] as? String {
        case "host": return .host
        case "cohost": return .cohost
        default: return .audience
        }
    }

    /// Whether this user can publish. Convenient for laying out a stage.
    public var isPublisher: Bool { role != .audience }

    /// The metadata your own server put in the token, with our fields stripped out.
    public var attributes: [String: Any] {
        var map = parsed()
        map.removeValue(forKey: "appId")
        map.removeValue(forKey: "role")
        return map
    }

    /// The raw metadata string. Prefer `attributes`.
    public var metadata: String? { participant.metadata }

    private var cachedRaw: String?
    private var cachedValue: [String: Any]?

    /// Parsing runs once per metadata string, not once per read.
    private func parsed() -> [String: Any] {
        let raw = participant.metadata
        if let cached = cachedValue, cachedRaw == raw { return cached }
        var value: [String: Any] = [:]
        if let raw, !raw.isEmpty,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            value = object
        }
        cachedRaw = raw
        cachedValue = value
        return value
    }

    /// First available video track for rendering with `AppVideoView`.
    public var videoTrack: VideoTrack? {
        participant.videoTracks.compactMap { $0.track as? VideoTrack }.first
    }

    /// Whether this participant is currently publishing a camera.
    public var hasVideo: Bool { videoTrack != nil }

    /// internal — escape hatch for UIKits
    public var raw: RemoteParticipant { participant }
}

/// Channel event callbacks. All delivered on the main actor.
public protocol AppEngineDelegate: AnyObject {
    func appEngine(_ engine: AppEngine, userJoined user: AppRemoteUser)
    func appEngine(_ engine: AppEngine, userLeft user: AppRemoteUser)
    func appEngine(_ engine: AppEngine, trackSubscribedFor user: AppRemoteUser)
    func appEngine(_ engine: AppEngine, connectionStateChanged state: AppConnectionState)
    /// Someone sent a message with `sendMessage`.
    func appEngine(_ engine: AppEngine, messageReceived message: AppMessage)
    /// The audience changed — someone started or stopped watching.
    func appEngine(_ engine: AppEngine, audienceChanged audience: [AppRemoteUser])
    /// Raw bytes from `sendData`. Platform frames are not reported here.
    func appEngine(_ engine: AppEngine, dataReceived data: Data, from user: AppRemoteUser?)
    func appEngine(_ engine: AppEngine, giftReceived gift: AppGiftEvent)
    /// Your own camera track was (re)created — camera off→on, a switch, a
    /// settings change. Every `AppVideoView` showing you re-binds by itself.
    func appEngineLocalVideoChanged(_ engine: AppEngine)
    /// The first decoded frame of a remote user's camera reached your screen;
    /// `elapsedMs` counts from `joinChannel`.
    func appEngine(_ engine: AppEngine, firstRemoteVideoFrameFor uid: String, elapsedMs: Int)
    /// A milestone with elapsed ms since `joinChannel` — for measuring join latency.
    func appEngine(_ engine: AppEngine, connectionStage stage: AppConnectionStage, uid: String?, elapsedMs: Int)
    /// Per-remote-user media health, every two seconds while joined.
    func appEngine(_ engine: AppEngine, remoteStats stats: [AppRemoteStats])
    /// Who is talking right now (uids; may include your own `localUid`).
    func appEngine(_ engine: AppEngine, activeSpeakersChanged uids: [String])
    /// Someone muted or unmuted their camera or microphone.
    func appEngine(_ engine: AppEngine, userMediaChangedFor user: AppRemoteUser)
    /// The size, rate or layer your own camera is sending changed — the encoder
    /// stepped down for the network or the CPU, or came back up. Resolved from
    /// sender statistics while your camera is on.
    func appEngine(_ engine: AppEngine, videoQualityChanged quality: AppVideoQualityInfo)
    /// The audio route changed — a headset was connected or taken off, or
    /// `setAudioRoute` was called. `available` is what `audioRoutes` returns now.
    func appEngine(_ engine: AppEngine, audioRouteChanged route: AppAudioRoute?, available: [AppAudioRoute])
    /// Automatic codec recovery republished your camera on a safer path,
    /// because viewers were receiving it but could not show a picture. For
    /// logs and support; the app has nothing to do. At most once per join.
    /// `from` / `to` are codec names (`"h264"` → `"vp8"`); a camera already on
    /// VP8 is republished as a single layer (`"vp8"` → `"vp8:single"`).
    /// `reason` is `"no_frames"`, `"encoder_error"` or `"viewers_cannot_decode"`.
    func appEngine(_ engine: AppEngine, videoCodecFallbackFrom from: String, to: String, reason: String)
    /// The join token expires in about 30 seconds (immediately, when less than
    /// that was left at join or at `renewToken`). Fetch a new one from your
    /// server and pass it to `renewToken(_:)`.
    func appEngine(_ engine: AppEngine, tokenWillExpire token: String)
    /// A network fallback set with `setRemoteSubscribeFallback(_:)` (isLocal
    /// false) or `setLocalPublishFallback(_:)` (isLocal true) took effect;
    /// `.none` means everything was restored.
    func appEngine(_ engine: AppEngine, fallbackStateChanged state: AppFallbackOption, isLocal: Bool)
    /// The cloud proxy state changed (see `AppEngineOptions.cloudProxy`).
    /// `autoRetry` is true when the relay is used because the direct join failed.
    func appEngine(_ engine: AppEngine, proxyStateChanged state: AppProxyState, autoRetry: Bool)
}

// Default empty implementations so integrators override only what they need.
public extension AppEngineDelegate {
    func appEngine(_ engine: AppEngine, userJoined user: AppRemoteUser) {}
    func appEngine(_ engine: AppEngine, userLeft user: AppRemoteUser) {}
    func appEngine(_ engine: AppEngine, trackSubscribedFor user: AppRemoteUser) {}
    func appEngine(_ engine: AppEngine, connectionStateChanged state: AppConnectionState) {}
    func appEngine(_ engine: AppEngine, messageReceived message: AppMessage) {}
    func appEngine(_ engine: AppEngine, audienceChanged audience: [AppRemoteUser]) {}
    func appEngine(_ engine: AppEngine, dataReceived data: Data, from user: AppRemoteUser?) {}
    func appEngine(_ engine: AppEngine, giftReceived gift: AppGiftEvent) {}
    func appEngineLocalVideoChanged(_ engine: AppEngine) {}
    func appEngine(_ engine: AppEngine, firstRemoteVideoFrameFor uid: String, elapsedMs: Int) {}
    func appEngine(_ engine: AppEngine, connectionStage stage: AppConnectionStage, uid: String?, elapsedMs: Int) {}
    func appEngine(_ engine: AppEngine, remoteStats stats: [AppRemoteStats]) {}
    func appEngine(_ engine: AppEngine, activeSpeakersChanged uids: [String]) {}
    func appEngine(_ engine: AppEngine, userMediaChangedFor user: AppRemoteUser) {}
    func appEngine(_ engine: AppEngine, videoQualityChanged quality: AppVideoQualityInfo) {}
    func appEngine(_ engine: AppEngine, audioRouteChanged route: AppAudioRoute?, available: [AppAudioRoute]) {}
    func appEngine(_ engine: AppEngine, videoCodecFallbackFrom from: String, to: String, reason: String) {}
    func appEngine(_ engine: AppEngine, tokenWillExpire token: String) {}
    func appEngine(_ engine: AppEngine, fallbackStateChanged state: AppFallbackOption, isLocal: Bool) {}
    func appEngine(_ engine: AppEngine, proxyStateChanged state: AppProxyState, autoRetry: Bool) {}
}

/// Main entry point of the AppLooma RTC SDK.
///
/// One engine is one connection to one channel. To be in two channels at once
/// (a PK battle, watching a second stream) create a second engine; instances
/// are independent and any number may coexist.
public final class AppEngine {
    public let appId: String
    public let options: AppEngineOptions
    public weak var delegate: AppEngineDelegate?
    /// Built-in camera enhancement (see VideoEnhance.swift).
    var videoEnhanceFilter: AppVideoEnhanceFilter?

    let room: Room
    private var users: [String: AppRemoteUser] = [:]
    public private(set) var isJoined = false

    // Per-remote-user health, folded from track statistics.
    private final class Health {
        var fps = 0, width = 0, height = 0, freezes = 0, vLost = 0, aLost = 0, jitterMs = 0
        var firstFrameReported = false
        // Automatic codec recovery, viewer side.
        var noFrameSince: Date?
        var lastReportAt: Date?
    }
    private var health: [String: Health] = [:]
    private var trackOwner: [String: String] = [:] // track sid -> uid
    private var statsTimer: Timer?
    private var joinStartedAt: Date?
    /// Remote diagnostics ring and uploader (see `uploadDiagnostics(reason:)`).
    let diag = DiagCollector()
    private var lastDiagStatsAt = Date.distantPast

    #if canImport(UIKit)
    // Self-views; re-bound on every local track change.
    let localViews = NSHashTable<AppVideoView>.weakObjects()
    #endif

    private init(appId: String, delegate: AppEngineDelegate?, options: AppEngineOptions) {
        self.appId = appId
        self.delegate = delegate
        self.options = options
        let device = DeviceConfigStore.current
        self.activeDevice = device
        self.room = Room(roomOptions: Self.roomOptions(options, device: device))
        self.room.add(delegate: self)
        Self.configureAudioSession(for: options.audioScenario, clearVoice: options.audio.effectiveNoiseSuppression == .clear)
        observeAudioRoute()
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    // MARK: - Audio route

    private var routeObserver: NSObjectProtocol?

    private func observeAudioRoute() {
        #if os(iOS)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let route = self.currentAudioRoute, available = self.audioRoutes
            Task { @MainActor in self.delegate?.appEngine(self, audioRouteChanged: route, available: available) }
        }
        #endif
    }

    #if os(iOS)
    private static func route(for port: AVAudioSession.Port) -> AppAudioRoute? {
        switch port {
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return .bluetooth
        case .headphones, .headsetMic, .usbAudio: return .wiredHeadset
        case .builtInReceiver: return .earpiece
        case .builtInSpeaker: return .speaker
        default: return nil
        }
    }
    #endif

    /// The output audio is going to right now; nil when the session is not
    /// active yet (before the first join).
    public var currentAudioRoute: AppAudioRoute? {
        #if os(iOS)
        return AVAudioSession.sharedInstance().currentRoute.outputs.lazy.compactMap { Self.route(for: $0.portType) }.first
        #else
        return nil
        #endif
    }

    /// The outputs that can be selected right now, best first: a Bluetooth
    /// headset when one is connected, wired headphones, then the earpiece and
    /// the loudspeaker. Feed it to an in-call route picker.
    public var audioRoutes: [AppAudioRoute] {
        #if os(iOS)
        var routes: [AppAudioRoute] = []
        for input in AVAudioSession.sharedInstance().availableInputs ?? [] {
            if let r = Self.route(for: input.portType), r != .earpiece, r != .speaker, !routes.contains(r) { routes.append(r) }
        }
        #if canImport(UIKit)
        if UIDevice.current.userInterfaceIdiom == .phone { routes.append(.earpiece) }
        #else
        routes.append(.earpiece)
        #endif
        routes.append(.speaker)
        return routes
        #else
        return []
        #endif
    }

    /// Send audio to one specific output — for an in-call route picker
    /// ("iPhone / Speaker / AirPods"). Returns false when that output is not in
    /// `audioRoutes` (nothing changes). A headset that connects later takes over
    /// by itself, as it does for a phone call; the delegate's
    /// `audioRouteChanged` reports every change.
    @discardableResult
    public func setAudioRoute(_ route: AppAudioRoute) -> Bool {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        guard audioRoutes.contains(route) else { return false }
        do {
            switch route {
            case .speaker:
                try session.overrideOutputAudioPort(.speaker)
            case .earpiece:
                // `.media` sessions carry `.defaultToSpeaker`, under which
                // clearing the override lands on the speaker again — drop it.
                var opts = session.categoryOptions
                opts.remove(.defaultToSpeaker)
                if opts != session.categoryOptions { try session.setCategory(session.category, mode: session.mode, options: opts) }
                try session.overrideOutputAudioPort(.none)
                if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) { try session.setPreferredInput(mic) }
            case .bluetooth, .wiredHeadset:
                // Picking the headset's microphone as the preferred input moves
                // the output with it, which is the only way to steer between two
                // connected headsets without touching the category.
                try session.overrideOutputAudioPort(.none)
                if let input = session.availableInputs?.first(where: { Self.route(for: $0.portType) == route }) { try session.setPreferredInput(input) }
            }
            return true
        } catch {
            print("[AppLoomaRTC] setAudioRoute(\(route)): \(error)")
            return false
        }
        #else
        return false
        #endif
    }

    /// Route audio to the loudspeaker (true) or the earpiece (false). A
    /// connected Bluetooth or wired headset keeps priority either way.
    public func setSpeakerphone(_ on: Bool) {
        let routes = audioRoutes
        if let headset = routes.first(where: { $0 == .bluetooth || $0 == .wiredHeadset }) { setAudioRoute(headset); return }
        setAudioRoute(on ? .speaker : .earpiece)
    }

    /// The codec actually published, after `.auto` is resolved.
    public var publishedCodec: String {
        codecOverride ?? Self.deviceCodec(options.video.codec, resolved: configuredCodec, activeDevice)
    }

    /// Device tuning in effect for the current (or next) join.
    private var activeDevice: DeviceVideoConfig

    /// forceCodec always wins, preferCodec only replaces `.auto`; a codec the
    /// server marks as hardware-denied falls back to the next safer one.
    static func deviceCodec(_ app: AppVideoCodec, resolved: String, _ cfg: DeviceVideoConfig) -> String {
        var c = resolved
        if let f = cfg.forceCodec { c = f } else if app == .auto, let p = cfg.preferCodec { c = p }
        if c == "h265" && cfg.denyHardware.contains("video/hevc") { c = "h264" }
        if c == "h264" && cfg.denyHardware.contains("video/avc") { c = "vp8" }
        return c
    }

    private var configuredCodec: String {
        options.video.codec == .auto && options.video.mode == .ultraHd4k && Self.isUltraHdSupported() ? "h265" : Self.resolveCodec(options.video.codec)
    }

    // Own-camera quality, folded from sender statistics; reported on change only.
    private var lastQuality: AppVideoQualityInfo?
    private var lastVideoBytes: UInt64 = 0
    private var lastVideoAt: Date?

    /// Follow the sender statistics of a just-published camera track.
    private func watchLocalVideo(_ track: Track) {
        lastQuality = nil
        lastVideoBytes = 0
        lastVideoAt = nil
        track.add(delegate: self)
        Task { await track.set(reportStatistics: true) }
    }

    /// The top simulcast layer that carries frames right now, from one
    /// statistics report of our own camera track.
    private func reportLocalQuality(_ statistics: TrackStatistics) {
        let streams = statistics.outboundRtpStream
        guard !streams.isEmpty else { return }
        let now = Date()
        let bytes = streams.reduce(UInt64(0)) { $0 + ($1.bytesSent ?? 0) }
        var kbps = 0
        if let at = lastVideoAt, bytes >= lastVideoBytes {
            let secs = max(0.5, now.timeIntervalSince(at))
            kbps = Int(Double(bytes - lastVideoBytes) * 8 / secs / 1000)
        }
        lastVideoBytes = bytes
        lastVideoAt = now
        let active = streams.filter { ($0.framesPerSecond ?? 0) > 0 && ($0.frameHeight ?? 0) > 0 }
        guard let top = active.max(by: { ($0.frameHeight ?? 0) < ($1.frameHeight ?? 0) }) else { return }
        let h = Int(top.frameHeight ?? 0)
        let configured = Self.resolvedHeight(options.video)
        let layer: AppVideoLayer
        switch top.rid {
        case "f": layer = .high
        case "h": layer = .medium
        case "q": layer = .low
        default: layer = h >= Int(Double(configured) * 0.75) ? .high : (h >= Int(Double(configured) * 0.4) ? .medium : .low)
        }
        let reason: AppVideoQualityReason
        switch top.qualityLimitationReason {
        case .some(.bandwidth): reason = AppVideoQualityReason.bandwidth
        case .some(.cpu): reason = AppVideoQualityReason.cpu
        default: reason = AppVideoQualityReason.none
        }
        let q = AppVideoQualityInfo(width: Int(top.frameWidth ?? 0), height: h,
                                    fps: Int((top.framesPerSecond ?? 0).rounded()),
                                    bitrateKbps: kbps, layer: layer, reason: reason)
        let prev = lastQuality
        lastQuality = q
        guard let prev else { return } // the first sample is the baseline, not a change
        let same = prev.width == q.width && prev.height == q.height && prev.layer == q.layer &&
            prev.reason == q.reason && abs(prev.fps - q.fps) < 5
        if !same {
            Task { @MainActor in self.delegate?.appEngine(self, videoQualityChanged: q) }
        }
    }

    static func resolveCodec(_ c: AppVideoCodec) -> String {
        switch c {
        case .vp8: return "vp8"
        case .h264: return "h264"
        // Hardware on every iPhone since the 7.
        case .h265: return "h265"
        // No iPhone encodes AV1 in hardware; software AV1 cannot keep up at camera sizes.
        case .av1:
            print("[AppLoomaRTC] AppVideoCodec.av1 is not available on iOS; using auto")
            return "h264"
        // Every iPhone encodes H.264 in hardware; VP8 is software. A VP8 backup
        // layer covers any viewer that cannot decode the H.264 stream.
        case .auto: return "h264"
        }
    }

    static let presetHeights = [360, 540, 720, 1080, 1440, 2160]

    /// Whether this device can publish `AppVideoMode.ultraHd4k`. Not gated on
    /// iOS: every iPhone the SDK supports (A12 and later) encodes 2160p30 in
    /// hardware, so this returns true.
    public static func isUltraHdSupported() -> Bool { true }

    /// The height `c` captures at once the mode fills in the blanks.
    static func resolvedHeight(_ c: AppVideoConfig) -> Int {
        if c.height > 0 { return snapHeight(c.height) }
        switch c.mode {
        case .ultraHd4k: return isUltraHdSupported() ? 2160 : 1080
        case .stableHd, .adaptive: return 1080
        }
    }

    static func snapHeight(_ wanted: Int) -> Int {
        presetHeights.min(by: { abs($0 - wanted) < abs($1 - wanted) }) ?? 1080
    }

    /// `.auto` leaves the engine's per-source default (frame rate first for a camera).
    private static func degradation(_ d: AppVideoDegradation) -> DegradationPreference {
        switch d {
        case .keepResolution: return .maintainResolution
        case .keepFramerate: return .maintainFramerate
        case .balanced: return .balanced
        case .auto: return .auto
        }
    }

    private static func roomOptions(_ o: AppEngineOptions, codecOverride: String? = nil, simulcastOverride: Bool? = nil,
                                    device: DeviceVideoConfig = .empty, bitrateScale: Double = 1) -> RoomOptions {
        var mode = o.video.mode
        if mode == .ultraHd4k && !isUltraHdSupported() {
            print("[AppLoomaRTC] AppVideoMode.ultraHd4k is not supported on this device; using stableHd")
            mode = .stableHd
        }
        var height = resolvedHeight(o.video)
        // Device tuning only lowers caps, never raises them.
        if device.maxHeight > 0 && height > device.maxHeight {
            height = presetHeights.filter { $0 <= device.maxHeight }.max() ?? presetHeights[0]
        }
        if o.video.height > 0 && height != o.video.height { print("[AppLoomaRTC] AppVideoConfig.height=\(o.video.height) is not a preset; using \(height)p") }
        if o.video.maxBitrate > 0 && o.video.maxBitrate < 10_000 {
            print("[AppLoomaRTC] AppVideoConfig.maxBitrate=\(o.video.maxBitrate) is in bits per second — did you mean \(o.video.maxBitrate)_000 (kbps)?")
        }
        // In .ultraHd4k, .auto prefers H.265 (hardware on every supported iPhone).
        let codec = codecOverride ?? deviceCodec(o.video.codec, resolved: o.video.codec == .auto && mode == .ultraHd4k ? "h265" : resolveCodec(o.video.codec), device)
        // Our own caps. `.adaptive` keeps the earlier sharp-end caps (the
        // preset defaults were tuned for calls and leave 1080p visibly soft);
        // 540p and below keep theirs. minBitrate: the engine's encoding
        // carries no floor on iOS, so AppVideoConfig.minBitrate is not applied
        // here. No start-bitrate hook is exposed either.
        let adaptive = mode == .adaptive
        let dimensions: Dimensions
        let defaultBitrate: Int
        switch height {
        case 360: dimensions = .h360_169; defaultBitrate = 400_000
        case 540: dimensions = .h540_169; defaultBitrate = 800_000
        case 720: dimensions = .h720_169; defaultBitrate = adaptive ? 2_200_000 : 1_800_000
        case 1440: dimensions = .h1440_169; defaultBitrate = 5_000_000
        case 2160: dimensions = Dimensions(width: 3840, height: 2160); defaultBitrate = codec == "h265" ? 16_000_000 : 25_000_000
        default: dimensions = .h1080_169; defaultBitrate = adaptive ? 4_000_000 : 3_500_000
        }
        var maxBitrate = o.video.maxBitrate > 0 ? o.video.maxBitrate : defaultBitrate
        if device.maxBitrateKbps > 0 { maxBitrate = min(maxBitrate, device.maxBitrateKbps * 1000) }
        if bitrateScale < 1 { maxBitrate = max(300_000, Int(Double(maxBitrate) * bitrateScale)) }
        let maxFps = device.maxFps > 0 ? min(o.video.fps, device.maxFps) : o.video.fps
        let encoding = VideoEncoding(maxBitrate: maxBitrate, maxFps: maxFps)
        let simulcast = (simulcastOverride ?? o.video.simulcast ?? adaptive) && !device.disableSimulcast
        let wantedDegradation: AppVideoDegradation = o.video.degradation == .auto && !adaptive ? .keepResolution : o.video.degradation
        let preferred: VideoCodec
        switch codec {
        case "h264": preferred = .h264
        case "h265": preferred = .h265
        default: preferred = .vp8
        }
        return RoomOptions(
            defaultCameraCaptureOptions: CameraCaptureOptions(dimensions: dimensions),
            defaultAudioCaptureOptions: AudioCaptureOptions(
                echoCancellation: o.audio.echoCancellation,
                autoGainControl: o.audio.autoGainControl,
                noiseSuppression: o.audio.effectiveNoiseSuppression != .off
            ),
            defaultVideoPublishOptions: VideoPublishOptions(
                encoding: encoding,
                simulcast: simulcast,
                preferredCodec: preferred,
                // Anything but VP8 rides with a VP8 backup layer so a viewer
                // whose device cannot decode it is served VP8 by the server
                // instead of a black frame.
                preferredBackupCodec: codec == "vp8" ? nil : .vp8,
                degradationPreference: degradation(wantedDegradation)
            ),
            defaultAudioPublishOptions: AudioPublishOptions(
                encoding: AudioEncoding(maxBitrate: 96_000),
                dtx: false,
                red: true
            ),
            // `.adaptive`: adaptive stream down-shifts a remote layer for a
            // small or hidden view. `.stableHd` / `.ultraHd4k` turn it off so a
            // receiver keeps the full picture. Dynacast is OFF: with it on, a
            // publisher withholds a video layer until a subscriber's "viewing"
            // signal arrives, which on flaky links left co-hosts staring at a
            // black frame.
            adaptiveStream: adaptive,
            dynacast: false,
            reportRemoteTrackStatistics: true
        )
    }

    /// `.media` keeps the loudspeaker and music-grade playback but stays in
    /// playAndRecord + videoChat so the platform echo canceller is engaged —
    /// the plain playback category has no canceller, and a loudspeaker session
    /// then feeds itself back after a minute or two.
    private static func configureAudioSession(for scenario: AppAudioScenario, clearVoice: Bool = false) {
        #if os(iOS)
        AudioManager.shared.customConfigureAudioSessionFunc = { newState, _ in
            let session = AVAudioSession.sharedInstance()
            do {
                if newState.trackState == .none {
                    try session.setActive(false, options: .notifyOthersOnDeactivation)
                    return
                }
                switch scenario {
                case .media:
                    // Clear Voice: voice-chat mode, the platform's strongest voice processing.
                    try session.setCategory(.playAndRecord, mode: clearVoice ? .voiceChat : .videoChat,
                                            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
                case .call:
                    try session.setCategory(.playAndRecord, mode: .voiceChat,
                                            options: [.allowBluetooth, .allowBluetoothA2DP])
                }
                try session.setActive(true)
            } catch {
                print("[AppLoomaRTC] audio session: \(error)")
            }
        }
        #endif
    }

    #if os(iOS)
    /// The video codecs this device can send and receive. H.264 is always
    /// hardware on iOS; H.265 is listed when VideoToolbox can decode it in
    /// hardware, and as an encoder when the device can also export HEVC.
    /// VP8 and VP9 run in software.
    public static func getSupportedVideoCodecs() -> [AppVideoCodecCapability] {
        var out = [
            AppVideoCodecCapability(mime: "video/VP8", hardware: false, encoder: true, decoder: true),
            AppVideoCodecCapability(mime: "video/VP9", hardware: false, encoder: true, decoder: true),
            AppVideoCodecCapability(mime: "video/H264", hardware: true, encoder: true,
                                    decoder: VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)),
        ]
        let hevcDecode = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let hevcEncode = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
        if hevcDecode || hevcEncode {
            out.append(AppVideoCodecCapability(mime: "video/H265", hardware: true, encoder: hevcEncode, decoder: hevcDecode))
        }
        return out
    }

    /// Opens the system microphone-mode picker (Standard, Voice Isolation,
    /// Wide Spectrum) while the microphone is live. Voice Isolation is the
    /// strongest noise removal on iOS and only the user can switch it on.
    /// iOS 15 and later; does nothing before.
    public static func showMicrophoneModes() {
        if #available(iOS 15.0, *) { AVCaptureDevice.showSystemUserInterface(.microphoneModes) }
    }

    /// True while the user has Voice Isolation on for this app (iOS 15+).
    public static var isVoiceIsolationActive: Bool {
        if #available(iOS 15.0, *) { return AVCaptureDevice.activeMicrophoneMode == .voiceIsolation }
        return false
    }
    #endif

    /// Create an engine instance with your AppLooma RTC App ID (applooma.dev/dashboard).
    public static func create(appId: String, delegate: AppEngineDelegate? = nil, options: AppEngineOptions = AppEngineOptions()) -> AppEngine {
        precondition(!appId.isEmpty, "AppEngine.create: appId is required")
        return AppEngine(appId: appId, delegate: delegate, options: options)
    }

    private func elapsedMs() -> Int {
        guard let start = joinStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Join a channel with a token from your server
    /// (POST https://api.applooma.dev/v1/token → { token, wsUrl }).
    public func joinChannel(token: String, wsUrl: String, options: AppJoinOptions = AppJoinOptions()) async throws {
        guard !isJoined else { throw AppError.alreadyJoined }
        joinStartedAt = Date()
        fallbackUsed = false
        viewerReports.removeAll()
        joinToken = token
        reportedOutcomes.removeAll()
        diag.enabled = self.options.remoteDiagnostics
        diag.begin(token: token, region: self.options.region.rawValue)
        // Device tuning: this join uses the cached answer; a fresh one is
        // fetched in the background and applies to the next join. Never
        // blocks the join.
        activeDevice = DeviceConfigStore.current
        DeviceConfigStore.refresh(token: token, region: self.options.region.rawValue)
        resetFallbacks()
        diag.log("joinChannel region=\(self.options.region.rawValue) codec=\(publishedCodec) camera=\(options.camera) mic=\(options.microphone)")
        print("[AppLoomaRTC] joining (region: \(self.options.region.rawValue))")
        // Auto-subscribe so an audience member (and every co-host) receives all
        // published tracks the moment they join.
        do {
            try await connectWithProxy(url: wsUrl, token: token,
                                       roomOptions: Self.roomOptions(self.options, codecOverride: codecOverride, simulcastOverride: simulcastOverride, device: activeDevice))
        } catch {
            diag.log("join failed: \(error)")
            diag.problem("join_failed")
            diag.end("join failed")
            throw error
        }
        isJoined = true
        diag.log("connected in \(elapsedMs()) ms")
        let ms = elapsedMs()
        Task { @MainActor in self.delegate?.appEngine(self, connectionStage: .connected, uid: nil, elapsedMs: ms) }

        // Participants already in the room when we join never produce a
        // participantDidConnect callback; without this an audience member
        // joining a live stream sees nobody and never receives the host's video.
        seedExistingParticipants()
        startStats()
        armTokenExpiry()

        // Audience latency: no receive-side jitter-buffer control on iOS, so
        // only `.standard` acts, by preferring lower video layers under congestion.
        if options.role == .audience && self.options.audienceLatency == .standard && subscribeFallback == .none {
            setRemoteSubscribeFallback(.videoLowQuality)
        }
        if options.role != .audience {
            if options.microphone { try await room.localParticipant.setMicrophone(enabled: true) }
            if options.camera { try await room.localParticipant.setCamera(enabled: true) }
        }
    }

    public func leaveChannel() async {
        diag.end("leave")
        stopStats()
        cancelTokenExpiry()
        resetFallbacks()
        await room.disconnect()
        isJoined = false
        users.removeAll()
        setProxyState(.direct, autoRetry: false)
    }

    /// Announces everyone already present, and their already-published tracks.
    private func seedExistingParticipants() {
        for participant in room.remoteParticipants.values {
            let user = userFor(participant)
            var hasTrack = false
            for pub in participant.trackPublications.values {
                if let track = pub.track { hasTrack = true; watch(track, for: user) }
            }
            let has = hasTrack
            Task { @MainActor in
                self.delegate?.appEngine(self, userJoined: user)
                if has { self.delegate?.appEngine(self, trackSubscribedFor: user) }
            }
        }
    }

    // MARK: - Local media controls

    public func enableCamera(_ on: Bool = true) async throws {
        try await room.localParticipant.setCamera(enabled: on)
        notifyLocalVideoChanged()
    }

    public func enableMicrophone(_ on: Bool = true) async throws {
        try await room.localParticipant.setMicrophone(enabled: on)
    }

    /// Flip between the front and back cameras. Does nothing until the camera is on.
    public func switchCamera() async throws {
        guard let track = localVideoTrack as? LocalVideoTrack,
              let capturer = track.capturer as? CameraCapturer else { return }
        try await capturer.switchCameraPosition()
        notifyLocalVideoChanged()
    }

    /// The local camera track was replaced (on/off, switch, config). Re-bind
    /// every self-view and tell the app.
    func notifyLocalVideoChanged() {
        attachVideoEnhance()
        Task { @MainActor in
            #if canImport(UIKit)
            for view in self.localViews.allObjects { view.refreshLocal(engine: self) }
            #endif
            self.delegate?.appEngineLocalVideoChanged(self)
        }
    }

    /// Send a message to everyone in the channel.
    ///
    /// An audience member can call this even though they cannot publish video —
    /// which is what makes live comments on a broadcast work.
    ///
    /// Nothing is stored, so a message reaches whoever is present when it is sent.
    @discardableResult
    public func sendMessage(
        text: String? = nil,
        data: [String: Any]? = nil,
        reliable: Bool = true
    ) async throws -> AppMessage {
        precondition(text != nil || data != nil, "sendMessage needs text or data")
        let message = AppMessage(
            id: Self.newMessageId(),
            text: text,
            data: data,
            from: nil,
            sentAt: Date()
        )
        var frame: [String: Any] = [
            "type": Self.messageType,
            "id": message.id,
            "sentAt": ISO8601DateFormatter().string(from: message.sentAt),
        ]
        if let text { frame["text"] = text }
        if let data { frame["data"] = data }
        try await sendData(JSONSerialization.data(withJSONObject: frame), reliable: reliable)
        return message
    }

    /// Broadcast raw bytes. Prefer `sendMessage` unless you need your own format.
    public func sendData(_ data: Data, reliable: Bool = true) async throws {
        try await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: reliable))
    }

    // MARK: - State

    /// Our own frames travel on the same channel as customer data, tagged so
    /// the two never mix.
    static let messageType = "applooma.message"
    static let giftType = "applooma.gift"

    private static let messageCounter = NSLock()
    private static var messageSeq: UInt64 = 0

    static func newMessageId() -> String {
        messageCounter.lock()
        defer { messageCounter.unlock() }
        messageSeq &+= 1
        return "m_\(UInt64(Date().timeIntervalSince1970 * 1000))_\(messageSeq)"
    }

    public var localUid: String { room.localParticipant.identity?.stringValue ?? "" }
    public var channelName: String { room.name ?? "" }
    public var remoteUsers: [AppRemoteUser] { Array(users.values) }

    /// Everyone watching without publishing. The live audience of a broadcast.
    public var audience: [AppRemoteUser] { users.values.filter { !$0.isPublisher } }

    /// How many people are watching.
    public var audienceCount: Int { users.values.reduce(0) { $0 + ($1.isPublisher ? 0 : 1) } }

    /// Everyone on stage: the host and any co-hosts, excluding you.
    public var hosts: [AppRemoteUser] { users.values.filter { $0.isPublisher } }

    /// Local camera track for preview rendering.
    public var localVideoTrack: VideoTrack? {
        room.localParticipant.videoTracks.compactMap { $0.track as? VideoTrack }.first
    }

    /// internal — escape hatch for UIKits
    public var raw: Room { room }

    func userFor(_ p: RemoteParticipant) -> AppRemoteUser {
        let key = p.identity?.stringValue ?? ""
        if let existing = users[key] { return existing }
        let u = AppRemoteUser(p)
        users[key] = u
        return u
    }

    func removeUser(_ p: RemoteParticipant) -> AppRemoteUser? {
        let key = p.identity?.stringValue ?? ""
        health.removeValue(forKey: key)
        return users.removeValue(forKey: key)
    }

    // MARK: - Remote health

    private func watch(_ track: Track, for user: AppRemoteUser) {
        if health[user.uid] == nil { health[user.uid] = Health() }
        if let sid = track.sid?.stringValue { trackOwner[sid] = user.uid }
        track.add(delegate: self)
    }

    private func startStats() {
        stopStats()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.isJoined else { return }
            let stats = self.health.map { uid, h in
                AppRemoteStats(uid: uid, videoFps: h.fps, videoWidth: h.width, videoHeight: h.height,
                               videoFreezeCount: h.freezes, videoPacketsLost: h.vLost,
                               audioPacketsLost: h.aLost, audioJitterMs: h.jitterMs)
            }
            if !stats.isEmpty { self.delegate?.appEngine(self, remoteStats: stats) }
            if Date().timeIntervalSince(self.lastDiagStatsAt) >= 10 {
                self.lastDiagStatsAt = Date()
                let minFps = stats.map { $0.videoFps }.min() ?? -1
                let freezes = stats.reduce(0) { $0 + $1.videoFreezeCount }
                self.diag.log("stats codec=\(self.publishedCodec) remotes=\(stats.count) minRemoteFps=\(minFps) freezes=\(freezes)")
            }
            for (uid, h) in self.health { self.checkUndecodable(uid: uid, health: h) }
            self.applyFallbacks()
        }
    }

    // MARK: - Automatic codec recovery

    /// Reserved data topics: anything starting with `_al.` is SDK-internal and
    /// never reaches `messageReceived` or `dataReceived`.
    static let internalTopicPrefix = "_al."
    static let videoReportTopic = "_al.vq"

    private var codecOverride: String?
    private var simulcastOverride: Bool?
    private var viewerReports: [String: Date] = [:]
    private var fallbackUsed = false
    // Anonymous device reports: at most one per outcome and codec per join.
    private var joinToken: String?
    private var reportedOutcomes = Set<String>()

    private func reportDevice(_ outcome: String, codec: String, fromCodec: String? = nil, toCodec: String? = nil) {
        guard reportedOutcomes.insert("\(outcome):\(codec)").inserted else { return }
        DeviceReports.send(token: joinToken, region: options.region.rawValue, outcome: outcome, codec: codec, fromCodec: fromCodec, toCodec: toCodec)
    }

    /// Viewer side: a subscribed, enabled camera whose sender has it on,
    /// decoding nothing for more than 6 s. Tell that publisher only, at most
    /// once per 20 s.
    private func checkUndecodable(uid: String, health h: Health) {
        let now = Date()
        let pub = users[uid]?.raw.videoTracks.first as? RemoteTrackPublication
        guard let pub, pub.isSubscribed, pub.isEnabled, !pub.isMuted, h.fps == 0 else {
            h.noFrameSince = nil
            return
        }
        let since = h.noFrameSince ?? now
        h.noFrameSince = since
        guard now.timeIntervalSince(since) > 6 else { return }
        if let last = h.lastReportAt, now.timeIntervalSince(last) < 20 { return }
        h.lastReportAt = now
        let body: [String: Any] = ["v": 1, "t": "no_frames", "codec": pub.mimeType]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        Task {
            try? await self.room.localParticipant.publish(
                data: data,
                options: DataPublishOptions(destinationIdentities: [Participant.Identity(from: uid)], topic: Self.videoReportTopic, reliable: true)
            )
        }
    }

    /// Publisher side: a viewer reports no picture from our camera.
    fileprivate func onVideoReport(_ data: Data, from participant: RemoteParticipant?) {
        guard let viewer = participant?.identity?.stringValue,
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              msg["t"] as? String == "no_frames" else { return }
        guard let pub = room.localParticipant.videoTracks.first(where: { $0.source == .camera }),
              pub.track != nil, !pub.isMuted else { return }
        let now = Date()
        viewerReports[viewer] = now
        viewerReports = viewerReports.filter { now.timeIntervalSince($0.value) <= 20 }
        reportDevice("viewers_cannot_decode", codec: publishedCodec)
        diag.log("viewer uid=\(viewer) reports no picture codec=\(publishedCodec)")
        diag.problem("no_frames")
        // Two distinct viewers within 20 s, or the only other person in a 1:1.
        if viewerReports.count >= 2 || room.remoteParticipants.count <= 1 {
            Task { await self.fallBack(reason: "viewers_cannot_decode") }
        }
    }

    /// Republish the camera on a safer path: VP8 when it was on anything
    /// else, otherwise once more as a single layer. At most once per join.
    private func fallBack(reason: String) async {
        guard !fallbackUsed,
              let pub = room.localParticipant.videoTracks.first(where: { $0.source == .camera }) as? LocalTrackPublication,
              pub.track != nil else { return }
        fallbackUsed = true
        let from = publishedCodec
        let to: String
        if from != "vp8" {
            codecOverride = "vp8"
            to = "vp8"
        } else {
            simulcastOverride = false
            to = "vp8:single"
        }
        print("[AppLoomaRTC] codec recovery: \(from) -> \(to) (\(reason))")
        diag.log("codec recovery: \(from) -> \(to) reason=\(reason)")
        diag.problem("fallback")
        reportDevice("fallback", codec: from, fromCodec: from, toCodec: "vp8")
        let recovered = Self.roomOptions(options, codecOverride: codecOverride, simulcastOverride: simulcastOverride, device: activeDevice)
        guard await republishCamera(pub, with: recovered, what: "codec recovery") else { return }
        Task { @MainActor in self.delegate?.appEngine(self, videoCodecFallbackFrom: from, to: to, reason: reason) }
    }

    /// Unpublishes the camera and publishes it again with `recovered`'s
    /// capture and publish options, on the camera in use (front or back).
    private func republishCamera(_ pub: LocalTrackPublication, with recovered: RoomOptions, what: String) async -> Bool {
        let publish = recovered.defaultVideoPublishOptions
        let defaults = recovered.defaultCameraCaptureOptions
        let position = ((pub.track as? LocalVideoTrack)?.capturer as? CameraCapturer)?.position ?? defaults.position
        let capture = CameraCaptureOptions(position: position, dimensions: defaults.dimensions, fps: defaults.fps)
        do {
            try await room.localParticipant.unpublish(publication: pub)
            try await room.localParticipant.setCamera(enabled: true, captureOptions: capture, publishOptions: publish)
        } catch {
            print("[AppLoomaRTC] \(what) failed: \(error)")
            diag.log("\(what) failed: \(error)")
            return false
        }
        notifyLocalVideoChanged()
        return true
    }

    // MARK: - Cloud proxy

    /// Current cloud proxy state (see `AppEngineOptions.cloudProxy`).
    public private(set) var proxyState: AppProxyState = .direct
    /// True while the AUTO retry tears down the failed direct attempt.
    private var proxyRetrying = false

    private func setProxyState(_ state: AppProxyState, autoRetry: Bool) {
        guard state != proxyState else { return }
        proxyState = state
        diag.log("cloud proxy \(state)\(autoRetry ? " (auto retry)" : "")")
        Task { @MainActor in self.delegate?.appEngine(self, proxyStateChanged: state, autoRetry: autoRetry) }
    }

    /// Whether a failed direct join is worth one retry through the relay: a
    /// connection or network timeout, not a refused token.
    static func isProxyRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let text = "\(error) \(error.localizedDescription)".lowercased()
        let refused = ["401", "403", "unauthorized", "unauthorised", "forbidden", "permission", "invalid token",
                       "token is expired", "not allowed", "already", "cancelled"]
        if refused.contains(where: { text.contains($0) }) { return false }
        let network = ["timedout", "timed out", "timeout", "network", "transport", " ice", "connection", "connect",
                       "unreachable", "socket", "peer"]
        return network.contains(where: { text.contains($0) })
    }

    /// Relay-only transport: media goes through the relay the server hands
    /// out in its ICE servers (TLS on 443).
    private static let relayConnectOptions = ConnectOptions(autoSubscribe: true, iceTransportPolicy: .relay)

    private func connectWithProxy(url: String, token: String, roomOptions: RoomOptions) async throws {
        let mode = options.cloudProxy
        if mode == .forceTls443 {
            setProxyState(.connecting, autoRetry: false)
            do {
                try await room.connect(url: url, token: token, connectOptions: Self.relayConnectOptions, roomOptions: roomOptions)
            } catch {
                setProxyState(.direct, autoRetry: false)
                throw error
            }
            setProxyState(.connected, autoRetry: false)
            return
        }
        do {
            try await room.connect(url: url, token: token, connectOptions: ConnectOptions(autoSubscribe: true), roomOptions: roomOptions)
        } catch {
            guard mode == .auto, Self.isProxyRetryable(error) else { throw error }
            diag.log("direct join failed; retrying once through the cloud proxy on TLS 443")
            print("[AppLoomaRTC] Direct connection failed; retrying through the AppLooma cloud proxy (TLS 443)")
            proxyRetrying = true
            await room.disconnect()
            proxyRetrying = false
            setProxyState(.connecting, autoRetry: true)
            do {
                try await room.connect(url: url, token: token, connectOptions: Self.relayConnectOptions, roomOptions: roomOptions)
            } catch {
                setProxyState(.direct, autoRetry: true)
                throw error
            }
            setProxyState(.connected, autoRetry: true)
        }
    }

    // MARK: - Network fallback

    private var subscribeFallback: AppFallbackOption = .none
    private var publishFallback: AppFallbackOption = .none
    private let downlinkPolicy = FallbackPolicy()
    private let uplinkPolicy = FallbackPolicy()
    /// Users whose video the subscribe fallback turned off (to turn back on).
    private var fallbackHidden = Set<String>()
    /// The publish fallback paused the camera and will turn it back on.
    private var localFallbackMuted = false
    /// The publish fallback republished the camera at a lower bitrate.
    private var localFallbackLowered = false

    /// What to give up on the video you receive when the network is poor for
    /// about 4 s: `.videoLowQuality` asks for every remote camera's low layer
    /// (only where the sender publishes layers and adaptive stream is off),
    /// `.audioOnly` stops receiving remote video. Restored after about 10 s
    /// of good network. Reported by `fallbackStateChanged` with isLocal
    /// false. Default `.none`. On iOS the trigger is the media server's
    /// quality estimate for this device.
    public func setRemoteSubscribeFallback(_ option: AppFallbackOption) {
        guard option != subscribeFallback else { return }
        if downlinkPolicy.active { restoreSubscribe() }
        downlinkPolicy.reset()
        subscribeFallback = option
    }

    /// What to give up on the video you send when the network is poor for
    /// about 4 s: `.videoLowQuality` republishes the camera at 30 % of its
    /// bitrate (at least 300 kbps), `.audioOnly` pauses the camera. Restored
    /// after about 10 s of good network. Reported by `fallbackStateChanged`
    /// with isLocal true. Default `.none`.
    public func setLocalPublishFallback(_ option: AppFallbackOption) {
        guard option != publishFallback else { return }
        if uplinkPolicy.active { Task { await self.restorePublish() } }
        uplinkPolicy.reset()
        publishFallback = option
    }

    private static func quality(_ q: ConnectionQuality) -> AppNetworkQuality {
        switch q {
        case .excellent: return .excellent
        case .good: return .good
        case .poor: return .poor
        case .lost: return .lost
        default: return .unknown
        }
    }

    private func applyFallbacks() {
        let q = Self.quality(room.localParticipant.connectionQuality)
        let poor = q == .poor || q == .lost
        let good = q == .excellent || q == .good
        let now = Date()
        if subscribeFallback != .none {
            switch downlinkPolicy.onSample(now, poor: poor, good: good) {
            case .some(true):
                diag.log("fallback subscribe -> \(subscribeFallback)")
                let state = subscribeFallback
                Task { @MainActor in self.delegate?.appEngine(self, fallbackStateChanged: state, isLocal: false) }
            case .some(false):
                restoreSubscribe()
                diag.log("fallback subscribe restored")
                Task { @MainActor in self.delegate?.appEngine(self, fallbackStateChanged: .none, isLocal: false) }
            case .none: break
            }
            // Re-applied each tick so users who join during a fallback are covered too.
            if downlinkPolicy.active { applySubscribeFallback() }
        }
        if publishFallback != .none {
            switch uplinkPolicy.onSample(now, poor: poor, good: good) {
            case .some(true):
                let state = publishFallback
                Task {
                    await self.applyPublishFallback()
                    self.diag.log("fallback publish -> \(state)")
                    await MainActor.run { self.delegate?.appEngine(self, fallbackStateChanged: state, isLocal: true) }
                }
            case .some(false):
                Task {
                    await self.restorePublish()
                    self.diag.log("fallback publish restored")
                    await MainActor.run { self.delegate?.appEngine(self, fallbackStateChanged: .none, isLocal: true) }
                }
            case .none: break
            }
        }
    }

    private func applySubscribeFallback() {
        for (uid, user) in users {
            for case let pub as RemoteTrackPublication in user.raw.videoTracks {
                switch subscribeFallback {
                case .audioOnly:
                    if pub.isSubscribed {
                        fallbackHidden.insert(uid)
                        Task { try? await pub.set(subscribed: false) }
                    }
                case .videoLowQuality:
                    Task { try? await pub.set(videoQuality: .low) }
                case .none:
                    break
                }
            }
        }
    }

    private func restoreSubscribe() {
        for (uid, user) in users {
            for case let pub as RemoteTrackPublication in user.raw.videoTracks {
                if fallbackHidden.contains(uid) && !pub.isSubscribed { Task { try? await pub.set(subscribed: true) } }
                if subscribeFallback == .videoLowQuality { Task { try? await pub.set(videoQuality: .high) } }
            }
        }
        fallbackHidden.removeAll()
    }

    private func cameraPublication() -> LocalTrackPublication? {
        room.localParticipant.videoTracks.first(where: { $0.source == .camera }) as? LocalTrackPublication
    }

    private func applyPublishFallback() async {
        guard let pub = cameraPublication(), pub.track != nil, !pub.isMuted else { return }
        switch publishFallback {
        case .audioOnly:
            do {
                try await room.localParticipant.setCamera(enabled: false)
                localFallbackMuted = true
                notifyLocalVideoChanged()
            } catch {
                diag.log("fallback publish failed: \(error)")
            }
        case .videoLowQuality:
            let lowered = Self.roomOptions(options, codecOverride: codecOverride, simulcastOverride: simulcastOverride,
                                           device: activeDevice, bitrateScale: 0.3)
            localFallbackLowered = await republishCamera(pub, with: lowered, what: "fallback publish")
        case .none:
            break
        }
    }

    private func restorePublish() async {
        if localFallbackMuted && isJoined {
            localFallbackMuted = false
            do {
                try await room.localParticipant.setCamera(enabled: true)
                notifyLocalVideoChanged()
            } catch {
                diag.log("fallback restore failed: \(error)")
            }
        }
        localFallbackMuted = false
        if localFallbackLowered, isJoined, let pub = cameraPublication(), pub.track != nil {
            let full = Self.roomOptions(options, codecOverride: codecOverride, simulcastOverride: simulcastOverride, device: activeDevice)
            _ = await republishCamera(pub, with: full, what: "fallback restore")
        }
        localFallbackLowered = false
    }

    private func resetFallbacks() {
        downlinkPolicy.reset()
        uplinkPolicy.reset()
        fallbackHidden.removeAll()
        localFallbackMuted = false
        localFallbackLowered = false
    }

    // MARK: - Pre-call network test

    private var networkTestTask: Task<Void, Never>?

    /// Test the network before a call: opens a short, separate connection
    /// with `token` (mint it for a throwaway test channel, e.g.
    /// "nettest-<uid>"; nothing is published), samples the media server's
    /// quality estimate for about 5 s, leaves, and calls `completion` once on
    /// the main thread. Gives up after 10 s with `error` set. Does not touch
    /// the channel you are in. Honors `cloudProxy = .forceTls443`. Round-trip
    /// time, jitter and loss are not measured on iOS yet (-1 / -1 / 0): the
    /// media engine only exposes transport statistics per published or
    /// subscribed track, and this probe carries no media.
    public func startNetworkTest(serverUrl: String, token: String, completion: @escaping (AppNetworkTestResult) -> Void) {
        stopNetworkTest()
        let connectOptions = options.cloudProxy == .forceTls443 ? Self.relayConnectOptions : ConnectOptions(autoSubscribe: false)
        networkTestTask = Task { [weak self] in
            let probe = Room()
            let result: AppNetworkTestResult? = await withTaskGroup(of: AppNetworkTestResult?.self) { group in
                group.addTask {
                    do {
                        try await probe.connect(url: serverUrl, token: token, connectOptions: connectOptions)
                    } catch {
                        return Task.isCancelled ? nil : AppEngine.failedTest("could not connect")
                    }
                    var qualities: [AppNetworkQuality] = []
                    for _ in 0..<5 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        if Task.isCancelled { return nil }
                        qualities.append(AppEngine.quality(probe.localParticipant.connectionQuality))
                    }
                    // The worst reading of the window, so a spike is not hidden.
                    let worst = qualities.filter { $0 != .unknown }.max(by: { $0.rawValue < $1.rawValue }) ?? .unknown
                    return AppNetworkTestResult(uplinkQuality: worst, downlinkQuality: worst, rttMs: -1, jitterMs: -1,
                                                uplinkLoss: 0, downlinkLoss: 0, error: nil)
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    return Task.isCancelled ? nil : AppEngine.failedTest("timed out")
                }
                let first = (await group.next()) ?? nil
                group.cancelAll()
                return first
            }
            await probe.disconnect()
            guard !Task.isCancelled, let result else {
                self?.diag.log("network test stopped")
                return
            }
            await MainActor.run { completion(result) }
        }
    }

    /// Stop a running `startNetworkTest`; its completion is not called.
    public func stopNetworkTest() {
        networkTestTask?.cancel()
        networkTestTask = nil
    }

    private static func failedTest(_ error: String) -> AppNetworkTestResult {
        AppNetworkTestResult(uplinkQuality: .unknown, downlinkQuality: .unknown, rttMs: -1, jitterMs: -1,
                             uplinkLoss: 0, downlinkLoss: 0, error: error)
    }

    // MARK: - Token renewal

    private var tokenExpiryTimer: Timer?

    /// Replace the token the SDK keeps for its own later calls (device reports)
    /// and re-arm `tokenWillExpire`. While connected, the media server already
    /// refreshes the live connection's own credential, so the call itself is
    /// not interrupted. Stored even when not joined.
    public func renewToken(_ token: String) {
        joinToken = token
        diag.updateToken(token)
        diag.log("join token renewed")
        if isJoined { armTokenExpiry() }
    }

    /// Upload this device's recent SDK log lines to AppLooma support now (or
    /// with the next join when not in a channel), for example from a "report
    /// a problem" button. `reason` is a short label you choose. Only
    /// SDK-produced lines are sent, scrubbed of names, metadata, tokens and
    /// URL parameters; never audio, video or messages. Does nothing when
    /// `AppEngineOptions.remoteDiagnostics` is false.
    public func uploadDiagnostics(reason: String) {
        diag.request(reason)
    }

    /// `exp` (seconds since 1970) from a JWT's payload, decoded locally.
    static func tokenExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (payload["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private func armTokenExpiry() {
        cancelTokenExpiry()
        guard let token = joinToken, let exp = Self.tokenExpiry(token) else { return }
        // Less than 30 s left: fire (almost) immediately.
        let delay = max(0.05, exp.timeIntervalSinceNow - 30)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.isJoined, self.joinToken == token else { return }
            self.delegate?.appEngine(self, tokenWillExpire: token)
        }
        RunLoop.main.add(timer, forMode: .common)
        tokenExpiryTimer = timer
    }

    private func cancelTokenExpiry() {
        tokenExpiryTimer?.invalidate()
        tokenExpiryTimer = nil
    }

    private func stopStats() {
        statsTimer?.invalidate()
        statsTimer = nil
        health.removeAll()
        trackOwner.removeAll()
        lastQuality = nil
        lastVideoBytes = 0
        lastVideoAt = nil
    }
}

public enum AppError: Error {
    case alreadyJoined
}

// MARK: - RoomDelegate bridge

extension AppEngine: RoomDelegate {
    public func room(_ room: Room, participant: RemoteParticipant, didUpdateMetadata metadata: String?) {
        // A promotion or demotion rewrites the token metadata, which is how
        // someone moves between the stage and the audience mid-session.
        Task { @MainActor in self.delegate?.appEngine(self, audienceChanged: self.audience) }
    }

    public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let user = userFor(participant)
        Task { @MainActor in
            self.delegate?.appEngine(self, userJoined: user)
            self.delegate?.appEngine(self, audienceChanged: self.audience)
        }
    }

    public func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard let user = removeUser(participant) else { return }
        Task { @MainActor in
            self.delegate?.appEngine(self, userLeft: user)
            self.delegate?.appEngine(self, audienceChanged: self.audience)
        }
    }

    public func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let user = userFor(participant)
        if let track = publication.track { watch(track, for: user) }
        Task { @MainActor in self.delegate?.appEngine(self, trackSubscribedFor: user) }
    }

    public func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        publication.track?.remove(delegate: self)
    }

    // Our own camera was published, unpublished, or its track swapped on
    // mute/unmute: the moment self-views must re-bind.
    public func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        if publication.kind == .video {
            if publication.source == .camera, let track = publication.track { watchLocalVideo(track) }
            notifyLocalVideoChanged()
        }
    }

    public func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        if publication.kind == .video {
            publication.track?.remove(delegate: self)
            lastQuality = nil
            notifyLocalVideoChanged()
        }
    }

    public func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        if participant is LocalParticipant, trackPublication.kind == .video { notifyLocalVideoChanged() }
        if let remote = participant as? RemoteParticipant {
            let user = userFor(remote)
            Task { @MainActor in self.delegate?.appEngine(self, userMediaChangedFor: user) }
        }
    }

    public func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        let uids = participants.compactMap { $0.identity?.stringValue }
        Task { @MainActor in self.delegate?.appEngine(self, activeSpeakersChanged: uids) }
    }

    public func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from oldState: ConnectionState) {
        let mapped: AppConnectionState
        switch state {
        case .connecting: mapped = .connecting
        case .connected: mapped = .connected
        case .reconnecting: mapped = .reconnecting
        default: mapped = .disconnected
        }
        diag.log("connection \(mapped)")
        if case .reconnecting = state { diag.reconnecting() }
        if case .disconnected = state, !proxyRetrying {
            diag.end("disconnected")
            isJoined = false
            stopStats()
            cancelTokenExpiry()
            // Report everyone as gone; a stale roster after a disconnect made
            // remoteUsers wrong until the next join.
            let gone = Array(users.values)
            users.removeAll()
            Task { @MainActor in
                for user in gone { self.delegate?.appEngine(self, userLeft: user) }
            }
        }
        Task { @MainActor in self.delegate?.appEngine(self, connectionStateChanged: mapped) }
    }

    public func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        // SDK-internal traffic never reaches the app.
        if topic.hasPrefix(Self.internalTopicPrefix) {
            if topic == Self.videoReportTopic { onVideoReport(data, from: participant) }
            return
        }
        let user = participant.map { userFor($0) }

        // Each frame is either ours or the customer's, never both. Reporting our
        // own envelopes as raw data as well would deliver every comment twice to
        // anyone implementing both callbacks.
        let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let type = (frame ?? [:])["type"] as? String

        if type == Self.messageType, let frame {
            let message = AppMessage(
                id: frame["id"] as? String ?? Self.newMessageId(),
                text: frame["text"] as? String,
                data: frame["data"] as? [String: Any],
                from: user,
                sentAt: (frame["sentAt"] as? String)
                    .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
            )
            Task { @MainActor in self.delegate?.appEngine(self, messageReceived: message) }
            return
        }
        if type == Self.giftType, let gift = AppGiftEvent.tryParse(data) {
            Task { @MainActor in self.delegate?.appEngine(self, giftReceived: gift) }
            return
        }
        Task { @MainActor in self.delegate?.appEngine(self, dataReceived: data, from: user) }
    }
}

// MARK: - TrackDelegate: per-remote-user statistics

extension AppEngine: TrackDelegate {
    public func track(_ track: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics: [VideoCodec: TrackStatistics]) {
        // Our own camera: sender statistics, not a remote user's health.
        if track is LocalTrack {
            if track.kind == .video { reportLocalQuality(statistics) }
            return
        }
        guard let sid = track.sid?.stringValue, let uid = trackOwner[sid], let h = health[uid] else { return }
        for s in statistics.inboundRtpStream {
            if track.kind == .video {
                let fps = Int((s.framesPerSecond ?? 0).rounded())
                h.fps = fps
                h.width = Int(s.frameWidth ?? 0)
                h.height = Int(s.frameHeight ?? 0)
                h.freezes = Int(s.freezeCount ?? 0)
                h.vLost = Int(s.packetsLost ?? 0)
                if !h.firstFrameReported, (s.framesDecoded ?? 0) > 0 {
                    h.firstFrameReported = true
                    let ms = elapsedMs()
                    Task { @MainActor in
                        self.delegate?.appEngine(self, firstRemoteVideoFrameFor: uid, elapsedMs: ms)
                        self.delegate?.appEngine(self, connectionStage: .firstRemoteVideoFrame, uid: uid, elapsedMs: ms)
                    }
                }
            } else {
                h.aLost = Int(s.packetsLost ?? 0)
                if let delay = s.jitterBufferDelay, let emitted = s.jitterBufferEmittedCount, emitted > 0 {
                    h.jitterMs = Int(delay / Double(emitted) * 1000)
                }
            }
        }
    }
}

// MARK: - Virtual gifts

/// A virtual gift broadcast to the room (sent via your server's POST /v1/gifts/send).
public struct AppGiftEvent: Decodable {
    public struct GiftInfo: Decodable {
        public let id: String
        public let name: String
        public let imageUrl: String
        public let coinPrice: Int
    }
    public let txId: String
    public let gift: GiftInfo
    public let sender: String
    public let receiver: String
    public let quantity: Int

    /// Parses a data-channel payload; returns nil if it isn't a applooma.gift event.
    public static func tryParse(_ data: Data) -> AppGiftEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "applooma.gift",
              let decoded = try? JSONDecoder().decode(AppGiftEvent.self, from: data)
        else { return nil }
        return decoded
    }
}


// MARK: - Anonymous device reports

/// How the video encoder behaved on this phone (POST /v1/sdk/device-report).
/// Fire-and-forget: every error is swallowed, a call is never affected.
enum DeviceReports {
    static let sdkVersion = "0.5.7"
    static let apiBase = "https://api.applooma.dev/v1"

    private static func clean(_ s: String, _ max: Int) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._-+/(),:#")
        let mapped = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        let t = String(mapped.trimmingCharacters(in: .whitespaces).prefix(max))
        return t.isEmpty ? "unknown" : t
    }

    /// Hardware identifier such as "iPhone15,2".
    static var model: String {
        var info = utsname()
        uname(&info)
        let id = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return clean(id, 96)
    }

    static func send(token: String?, region: String = "auto", outcome: String, codec: String, fromCodec: String? = nil, toCodec: String? = nil) {
        guard let token, !token.isEmpty, let url = URL(string: "\(apiBase)/sdk/device-report") else { return }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var report: [String: String] = [
            "sdkPlatform": "ios",
            "sdkVersion": sdkVersion,
            "osName": "iOS",
            "osVersion": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "manufacturer": "Apple",
            "model": model,
            "codec": codec,
            "outcome": outcome,
            "region": region,
        ]
        if let fromCodec { report["fromCodec"] = fromCodec }
        if let toCodec { report["toCodec"] = toCodec }
        guard let body = try? JSONSerialization.data(withJSONObject: ["reports": [report]]) else { return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, _, _ in }.resume()
    }
}


// MARK: - Remote diagnostics

/// SDK log lines kept in memory (a fixed ring, nothing formatted on add) and
/// uploaded, scrubbed, to POST /v1/sdk/diag after a call with a problem, when
/// the device config asks for it, or on `uploadDiagnostics(reason:)`. Plain
/// JSON; a failed upload is kept in memory for the next join. Every error is
/// swallowed.
final class DiagCollector {
    private let lock = NSLock()
    private let capacity = 600
    private var times: [Date] = []
    private var lines: [String] = []
    private var next = 0
    var enabled = true
    private var remoteEnabled = false
    private var token: String?
    private var region = "auto"
    private var active = false
    private var problems = Set<String>()
    private var reconnects = 0
    private var appReason: String?
    private var uploaded = false
    private var midCall: Timer?
    private var pending: Data?

    func log(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        if lines.count < capacity {
            times.append(Date()); lines.append(line)
        } else {
            times[next] = Date(); lines[next] = line
            next = (next + 1) % capacity
        }
    }

    func problem(_ kind: String) {
        lock.lock(); problems.insert(kind); lock.unlock()
        log("diag: problem \(kind)")
    }

    func reconnecting() { lock.lock(); reconnects += 1; lock.unlock() }

    func updateToken(_ t: String) { lock.lock(); if active { token = t }; lock.unlock() }

    func begin(token: String, region: String) {
        lock.lock()
        self.token = token
        self.region = region
        active = true
        uploaded = false
        reconnects = 0
        let isOn = enabled
        let saved = pending
        lock.unlock()
        guard isOn else { return }
        if let saved { post(token: token, body: saved) { [weak self] ok in if ok { self?.lock.lock(); self?.pending = nil; self?.lock.unlock() } } }
        fetchRemoteFlag(token: token)
        midCall?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in self?.maybeUpload(final: false, force: false) }
        RunLoop.main.add(timer, forMode: .common)
        midCall = timer
    }

    func end(_ why: String) {
        lock.lock()
        let wasActive = active
        active = false
        lock.unlock()
        guard wasActive else { return }
        log("diag: session end (\(why))")
        midCall?.invalidate()
        midCall = nil
        maybeUpload(final: true, force: false)
    }

    func request(_ reason: String) {
        let clean = Self.clean(reason, 64)
        lock.lock(); appReason = clean; let isActive = active; lock.unlock()
        log("diag: app requested upload")
        if isActive { maybeUpload(final: false, force: true) }
    }

    /// Server-accepted characters only.
    static func clean(_ s: String, _ max: Int) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ._-+/(),:#")
        let mapped = String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " })
        let t = String(mapped.trimmingCharacters(in: .whitespaces).prefix(max))
        return t.isEmpty ? "app" : t
    }

    /// Engine names, tokens, URL parameters, names, metadata and user ids out.
    static func scrub(_ line: String) -> String {
        var s = line
        // Built from parts so the SDK source itself stays free of these names.
        let e1 = "live" + "kit", e2 = "web" + "rtc", e3 = "ago" + "ra"
        let rules: [(String, String)] = [
            (e1, "engine"), (e2, "rtc"), (e3, "vendor"),
            ("\\beyJ[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}\\.[A-Za-z0-9_-]{6,}", "[token]"),
            ("((?:https?|wss?)://[^\\s?#\"']+)\\?[^\\s\"']*", "$1?[redacted]"),
            ("\\b(token|access_token|secret|password|key|authorization)(\\s*[=:]\\s*)(\"[^\"]*\"|[^\\s,;&)}\\]]+)", "$1$2[redacted]"),
            ("\\b(name|displayName|metadata|attributes|userName|nickname)(\\s*[=:]\\s*)(\"[^\"]*\"|\\{[^}]*\\}|[^\\s,;)}\\]]+)", "$1$2[redacted]"),
            ("\\b(uid|localUid|identity|userId)(\\s*[=:]\\s*)([^\\s,;)}\\]]+)", "$1$2[id]"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        return String(s.prefix(1000))
    }

    /// (trigger, reason) or nil. An app request wins, then a problem, then remote collection.
    static func decide(enabled: Bool, appReason: String?, problems: Set<String>, reconnects: Int, remote: Bool) -> (String, String?)? {
        guard enabled else { return nil }
        if let appReason { return ("app_requested", appReason) }
        var all = problems
        if reconnects >= 3 { all.insert("reconnects") }
        if !all.isEmpty { return ("auto_problem", String(all.sorted().joined(separator: ",").prefix(64))) }
        if remote { return ("remote_enabled", nil) }
        return nil
    }

    private func snapshot(maxBytes: Int) -> [String] {
        lock.lock()
        let count = lines.count
        var ordered: [(Date, String)] = []
        for i in 0..<count {
            let k = count < capacity ? i : (next + i) % capacity
            ordered.append((times[k], lines[k]))
        }
        lock.unlock()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        fmt.timeZone = TimeZone(identifier: "UTC")
        var out: [String] = []
        var bytes = 0
        for (t, l) in ordered.reversed() {
            let s = fmt.string(from: t) + " " + Self.scrub(l)
            let n = s.utf8.count + 1
            if bytes + n > maxBytes { break }
            bytes += n
            out.append(s)
        }
        return out.reversed()
    }

    private func maybeUpload(final: Bool, force: Bool) {
        lock.lock()
        let d = Self.decide(enabled: enabled, appReason: appReason, problems: problems, reconnects: reconnects, remote: remoteEnabled)
        if final { problems.removeAll(); reconnects = 0 }
        let t = token
        let skip = d == nil || t == nil || (!final && !force && uploaded)
        if !skip {
            if d?.0 == "app_requested" { appReason = nil }
            uploaded = true
        }
        let region = self.region
        lock.unlock()
        guard !skip, let d, let t else { return }
        let lines = snapshot(maxBytes: 240 * 1024)
        guard !lines.isEmpty else { return }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var payload: [String: Any] = [
            "platform": "ios",
            "sdkVersion": DeviceReports.sdkVersion,
            "manufacturer": "Apple",
            "osVersion": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "region": region,
            "trigger": d.0,
            "lines": lines,
        ]
        if let reason = d.1 { payload["reason"] = reason }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        post(token: t, body: body) { [weak self] ok in
            // No network: keep the latest one for the next join.
            if !ok { self?.lock.lock(); self?.pending = body; self?.lock.unlock() }
        }
    }

    private func fetchRemoteFlag(token: String) {
        guard let url = URL(string: "\(DeviceReports.apiBase)/sdk/device-config?platform=ios&sdkVersion=\(DeviceReports.sdkVersion)") else { return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self, let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let on = (json["diag"] as? [String: Any])?["enabled"] as? Bool ?? false
            self.lock.lock(); self.remoteEnabled = on; self.lock.unlock()
        }.resume()
    }

    /// `done(false)` only when the server could not be reached.
    private func post(token: String, body: Data, done: @escaping (Bool) -> Void) {
        guard let url = URL(string: "\(DeviceReports.apiBase)/sdk/diag") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { _, response, _ in done(response != nil) }.resume()
    }
}


// MARK: - Network fallback policy

/// Hysteresis for one direction of network fallback: poor for `enter`
/// seconds enters the fallback, good for `exit` seconds leaves it. Anything in
/// between holds the current state and resets both timers.
final class FallbackPolicy {
    private let enter: TimeInterval
    private let exit: TimeInterval
    private(set) var active = false
    private var poorSince: Date?
    private var goodSince: Date?

    init(enter: TimeInterval = 4, exit: TimeInterval = 10) {
        self.enter = enter
        self.exit = exit
    }

    /// The new state when it changed on this sample, nil otherwise.
    func onSample(_ now: Date, poor: Bool, good: Bool) -> Bool? {
        if poor {
            goodSince = nil
            let since = poorSince ?? now
            poorSince = since
            if !active && now.timeIntervalSince(since) >= enter { active = true; return true }
        } else if good {
            poorSince = nil
            let since = goodSince ?? now
            goodSince = since
            if active && now.timeIntervalSince(since) >= exit { active = false; return false }
        } else {
            poorSince = nil
            goodSince = nil
        }
        return nil
    }

    func reset() {
        active = false
        poorSince = nil
        goodSince = nil
    }
}

// MARK: - Device tuning

/// Per-device video overrides decided by the AppLooma server (GET
/// /v1/sdk/device-config). Every field is optional; `.empty` means "use the
/// SDK defaults". Caps only lower what the app chose, never raise it.
struct DeviceVideoConfig: Equatable {
    var denyHardware: Set<String> = []
    var forceCodec: String?
    var preferCodec: String?
    var maxHeight = 0
    var maxFps = 0
    var maxBitrateKbps = 0
    var disableSimulcast = false
    var ttlSeconds: TimeInterval = 3600

    static let empty = DeviceVideoConfig()
    private static let codecs: Set<String> = ["vp8", "h264", "h265"]
    private static let mimes: Set<String> = ["video/avc", "video/hevc", "video/x-vnd.on2.vp8", "video/x-vnd.on2.vp9", "video/av01"]

    /// Unknown or malformed fields are ignored; nil when the body is not a JSON object.
    static func parse(_ data: Data?) -> DeviceVideoConfig? {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var cfg = DeviceVideoConfig()
        if let ttl = (root["ttlSeconds"] as? NSNumber)?.doubleValue, ttl > 0 { cfg.ttlSeconds = ttl }
        guard let v = root["video"] as? [String: Any] else { return cfg }
        func codec(_ key: String) -> String? {
            guard let c = (v[key] as? String)?.lowercased(), codecs.contains(c) else { return nil }
            return c
        }
        func positive(_ key: String) -> Int {
            guard let n = (v[key] as? NSNumber)?.intValue, n > 0 else { return 0 }
            return n
        }
        cfg.denyHardware = Set((v["denyHardware"] as? [Any] ?? []).compactMap { ($0 as? String)?.lowercased() }.filter { mimes.contains($0) })
        cfg.forceCodec = codec("forceCodec")
        cfg.preferCodec = codec("preferCodec")
        cfg.maxHeight = positive("maxHeight")
        cfg.maxFps = positive("maxFps")
        cfg.maxBitrateKbps = positive("maxBitrateKbps")
        cfg.disableSimulcast = (v["disableSimulcast"] as? Bool) == true
        return cfg
    }
}

/// The last good device-config answer, kept in UserDefaults with its ETag
/// and ttl so a join never waits for the network. Process-wide; every error
/// is swallowed and the call carries on with the SDK defaults.
enum DeviceConfigStore {
    private static let lock = NSLock()
    private static var cached: DeviceVideoConfig?
    private static var fetching = false
    private static let defaults = UserDefaults.standard
    private static let prefix = "applooma.devcfg."

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// A cached answer is only valid for the same device, OS and SDK.
    private static var key: String { "\(DeviceReports.model)|\(osVersion)|\(DeviceReports.sdkVersion)" }

    static var current: DeviceVideoConfig {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var cfg = DeviceVideoConfig.empty
        if defaults.string(forKey: prefix + "key") == key, let parsed = DeviceVideoConfig.parse(defaults.data(forKey: prefix + "body")) {
            cfg = parsed
        }
        cached = cfg
        return cfg
    }

    /// Refreshes in the background when the cached answer is older than its ttl.
    static func refresh(token: String, region: String) {
        guard !token.isEmpty else { return }
        let ttl = current.ttlSeconds
        let sameKey = defaults.string(forKey: prefix + "key") == key
        let at = defaults.double(forKey: prefix + "at")
        let now = Date().timeIntervalSince1970
        if sameKey && at > 0 && now - at >= 0 && now - at < ttl { return }
        lock.lock()
        if fetching { lock.unlock(); return }
        fetching = true
        lock.unlock()
        var comps = URLComponents(string: "\(DeviceReports.apiBase)/sdk/device-config")
        comps?.queryItems = [
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "sdkVersion", value: DeviceReports.sdkVersion),
            URLQueryItem(name: "manufacturer", value: "Apple"),
            URLQueryItem(name: "model", value: DeviceReports.model),
            URLQueryItem(name: "osVersion", value: osVersion),
            URLQueryItem(name: "region", value: region),
        ]
        guard let url = comps?.url else { lock.lock(); fetching = false; lock.unlock(); return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if sameKey, let etag = defaults.string(forKey: prefix + "etag") { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let cacheKey = key
        URLSession.shared.dataTask(with: req) { data, response, _ in
            DeviceConfigStore.store(data: data, response: response, cacheKey: cacheKey, now: now)
        }.resume()
    }

    private static func store(data: Data?, response: URLResponse?, cacheKey: String, now: TimeInterval) {
        defer { lock.lock(); fetching = false; lock.unlock() }
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 304 {
            defaults.set(now, forKey: prefix + "at")
            return
        }
        guard http.statusCode == 200, let cfg = DeviceVideoConfig.parse(data) else { return }
        defaults.set(cacheKey, forKey: prefix + "key")
        defaults.set(data, forKey: prefix + "body")
        defaults.set(http.value(forHTTPHeaderField: "ETag"), forKey: prefix + "etag")
        defaults.set(now, forKey: prefix + "at")
        lock.lock(); cached = cfg; lock.unlock()
    }
}
