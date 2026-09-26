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

/// Capture and encode settings for your own camera.
///
/// `maxBitrate` is in **bits per second** — `1_900_000` for 1.9 Mbps. A value
/// under 10 000 is almost certainly kbps by mistake and is logged as a warning.
/// `height` must be one of 360 / 540 / 720 / 1080; anything else snaps to the
/// nearest preset (also logged).
public struct AppVideoConfig: Sendable {
    /// 360, 540, 720, 1080 or 1440 — the short edge of a 16:9 frame.
    public var height: Int
    public var fps: Int
    /// Cap on the encoder's bitrate in bits per second; 0 = our default for the
    /// height (5 Mbps at 1440p, 4 Mbps at 1080p, 2.2 Mbps at 720p, the preset
    /// default below that).
    public var maxBitrate: Int
    public var simulcast: Bool
    public var codec: AppVideoCodec
    /// What to give up first under pressure. See `AppVideoDegradation`.
    public var degradation: AppVideoDegradation
    /// Floor on the encoder's bitrate in bits per second; 0 = engine default.
    /// Reserved: the engine exposes no per-sender minimum on iOS today, so the
    /// value is kept but does not change what is sent.
    public var minBitrate: Int

    public init(height: Int = 1080, fps: Int = 30, maxBitrate: Int = 0, simulcast: Bool = true, codec: AppVideoCodec = .auto,
                degradation: AppVideoDegradation = .auto, minBitrate: Int = 0) {
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

    public init(echoCancellation: Bool = true, noiseSuppression: Bool = true, autoGainControl: Bool = true) {
        self.echoCancellation = echoCancellation
        self.noiseSuppression = noiseSuppression
        self.autoGainControl = autoGainControl
    }
}

/// Engine-wide settings. All optional; the defaults are what most apps want.
public struct AppEngineOptions: Sendable {
    public var audioScenario: AppAudioScenario
    public var video: AppVideoConfig
    public var audio: AppAudioOptions

    public init(audioScenario: AppAudioScenario = .call, video: AppVideoConfig = AppVideoConfig(), audio: AppAudioOptions = AppAudioOptions()) {
        self.audioScenario = audioScenario
        self.video = video
        self.audio = audio
    }
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

    let room: Room
    private var users: [String: AppRemoteUser] = [:]
    public private(set) var isJoined = false

    // Per-remote-user health, folded from track statistics.
    private final class Health {
        var fps = 0, width = 0, height = 0, freezes = 0, vLost = 0, aLost = 0, jitterMs = 0
        var firstFrameReported = false
    }
    private var health: [String: Health] = [:]
    private var trackOwner: [String: String] = [:] // track sid -> uid
    private var statsTimer: Timer?
    private var joinStartedAt: Date?

    #if canImport(UIKit)
    // Self-views; re-bound on every local track change.
    let localViews = NSHashTable<AppVideoView>.weakObjects()
    #endif

    private init(appId: String, delegate: AppEngineDelegate?, options: AppEngineOptions) {
        self.appId = appId
        self.delegate = delegate
        self.options = options
        self.room = Room(roomOptions: Self.roomOptions(options))
        self.room.add(delegate: self)
        Self.configureAudioSession(for: options.audioScenario)
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
    public var publishedCodec: String { Self.resolveCodec(options.video.codec) }

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
        let configured = Self.snapHeight(options.video.height)
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

    static let presetHeights = [360, 540, 720, 1080, 1440]

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

    private static func roomOptions(_ o: AppEngineOptions) -> RoomOptions {
        let height = snapHeight(o.video.height)
        if height != o.video.height { print("[AppLoomaRTC] AppVideoConfig.height=\(o.video.height) is not a preset; using \(height)p") }
        if o.video.maxBitrate > 0 && o.video.maxBitrate < 10_000 {
            print("[AppLoomaRTC] AppVideoConfig.maxBitrate=\(o.video.maxBitrate) is in bits per second — did you mean \(o.video.maxBitrate)_000 (kbps)?")
        }
        // Our own caps for the sharp end: the preset defaults were tuned for
        // calls and leave 1080p visibly soft on a good link. 540p and below
        // keep theirs. minBitrate: the engine's encoding carries no floor on
        // iOS, so AppVideoConfig.minBitrate is not applied here.
        let dimensions: Dimensions
        let defaultBitrate: Int
        switch height {
        case 360: dimensions = .h360_169; defaultBitrate = 400_000
        case 540: dimensions = .h540_169; defaultBitrate = 800_000
        case 720: dimensions = .h720_169; defaultBitrate = 2_200_000
        case 1440: dimensions = .h1440_169; defaultBitrate = 5_000_000
        default: dimensions = .h1080_169; defaultBitrate = 4_000_000
        }
        let encoding = VideoEncoding(maxBitrate: o.video.maxBitrate > 0 ? o.video.maxBitrate : defaultBitrate, maxFps: o.video.fps)
        let codec = resolveCodec(o.video.codec)
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
                noiseSuppression: o.audio.noiseSuppression
            ),
            defaultVideoPublishOptions: VideoPublishOptions(
                encoding: encoding,
                simulcast: o.video.simulcast,
                preferredCodec: preferred,
                // Anything but VP8 rides with a VP8 backup layer so a viewer
                // whose device cannot decode it is served VP8 by the server
                // instead of a black frame.
                preferredBackupCodec: codec == "vp8" ? nil : .vp8,
                degradationPreference: degradation(o.video.degradation)
            ),
            defaultAudioPublishOptions: AudioPublishOptions(
                encoding: AudioEncoding(maxBitrate: 96_000),
                dtx: false,
                red: true
            ),
            // Adaptive stream still down-shifts a remote layer for a small or
            // hidden view. Dynacast is OFF: with it on, a publisher withholds a
            // video layer until a subscriber's "viewing" signal arrives, which on
            // flaky links left co-hosts staring at a black frame.
            adaptiveStream: true,
            dynacast: false,
            reportRemoteTrackStatistics: true
        )
    }

    /// `.media` keeps the loudspeaker and music-grade playback but stays in
    /// playAndRecord + videoChat so the platform echo canceller is engaged —
    /// the plain playback category has no canceller, and a loudspeaker session
    /// then feeds itself back after a minute or two.
    private static func configureAudioSession(for scenario: AppAudioScenario) {
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
                    try session.setCategory(.playAndRecord, mode: .videoChat,
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
        // Auto-subscribe so an audience member (and every co-host) receives all
        // published tracks the moment they join.
        try await room.connect(url: wsUrl, token: token, connectOptions: ConnectOptions(autoSubscribe: true))
        isJoined = true
        let ms = elapsedMs()
        Task { @MainActor in self.delegate?.appEngine(self, connectionStage: .connected, uid: nil, elapsedMs: ms) }

        // Participants already in the room when we join never produce a
        // participantDidConnect callback; without this an audience member
        // joining a live stream sees nobody and never receives the host's video.
        seedExistingParticipants()
        startStats()

        if options.role != .audience {
            if options.microphone { try await room.localParticipant.setMicrophone(enabled: true) }
            if options.camera { try await room.localParticipant.setCamera(enabled: true) }
        }
    }

    public func leaveChannel() async {
        stopStats()
        await room.disconnect()
        isJoined = false
        users.removeAll()
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
        }
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
        if case .disconnected = state {
            isJoined = false
            stopStats()
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
