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

/// Which codec your camera is published with.
///
/// `.auto` (default) publishes H.264 — hardware-encoded on every iPhone — with
/// a VP8 backup layer, so a viewer that cannot decode the H.264 stream still
/// gets a picture. Force one only for a known fleet.
public enum AppVideoCodec: Sendable {
    case auto, vp8, h264
}

/// Capture and encode settings for your own camera.
///
/// `maxBitrate` is in **bits per second** — `1_900_000` for 1.9 Mbps. A value
/// under 10 000 is almost certainly kbps by mistake and is logged as a warning.
/// `height` must be one of 360 / 540 / 720 / 1080; anything else snaps to the
/// nearest preset (also logged).
public struct AppVideoConfig: Sendable {
    public var height: Int
    public var fps: Int
    public var maxBitrate: Int
    public var simulcast: Bool
    public var codec: AppVideoCodec

    public init(height: Int = 1080, fps: Int = 30, maxBitrate: Int = 0, simulcast: Bool = true, codec: AppVideoCodec = .auto) {
        self.height = height
        self.fps = fps
        self.maxBitrate = maxBitrate
        self.simulcast = simulcast
        self.codec = codec
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
    }

    /// The codec actually published, after `.auto` is resolved.
    public var publishedCodec: String { Self.resolveCodec(options.video.codec) }

    static func resolveCodec(_ c: AppVideoCodec) -> String {
        switch c {
        case .vp8: return "vp8"
        case .h264: return "h264"
        // Every iPhone encodes H.264 in hardware; VP8 is software. A VP8 backup
        // layer covers any viewer that cannot decode the H.264 stream.
        case .auto: return "h264"
        }
    }

    private static func roomOptions(_ o: AppEngineOptions) -> RoomOptions {
        let heights = [360, 540, 720, 1080]
        let height = heights.min(by: { abs($0 - o.video.height) < abs($1 - o.video.height) }) ?? 1080
        if height != o.video.height { print("[AppLoomaRTC] AppVideoConfig.height=\(o.video.height) is not a preset; using \(height)p") }
        if o.video.maxBitrate > 0 && o.video.maxBitrate < 10_000 {
            print("[AppLoomaRTC] AppVideoConfig.maxBitrate=\(o.video.maxBitrate) is in bits per second — did you mean \(o.video.maxBitrate)_000 (kbps)?")
        }
        let dimensions: Dimensions
        let presetBitrate: Int
        switch height {
        case 360: dimensions = .h360_169; presetBitrate = 400_000
        case 540: dimensions = .h540_169; presetBitrate = 800_000
        case 720: dimensions = .h720_169; presetBitrate = 1_700_000
        default: dimensions = .h1080_169; presetBitrate = 3_000_000
        }
        let encoding = VideoEncoding(maxBitrate: o.video.maxBitrate > 0 ? o.video.maxBitrate : presetBitrate, maxFps: o.video.fps)
        let codec = resolveCodec(o.video.codec)
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
                preferredCodec: codec == "h264" ? .h264 : .vp8,
                // When H.264 is published, a VP8 layer rides along as backup so a
                // viewer whose device cannot decode it is served VP8 by the server
                // instead of a black frame.
                preferredBackupCodec: codec == "h264" ? .vp8 : nil
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
        if publication.kind == .video { notifyLocalVideoChanged() }
    }

    public func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        if publication.kind == .video { notifyLocalVideoChanged() }
    }

    public func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        if participant is LocalParticipant, trackPublication.kind == .video { notifyLocalVideoChanged() }
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
