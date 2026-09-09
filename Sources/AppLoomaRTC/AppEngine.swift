// AppLooma RTC iOS SDK — main entry point.
// © AppLooma LLC
//
//   let engine = AppEngine.create(appId: "YOUR_APP_ID", delegate: self)
//   try await engine.joinChannel(token: token, wsUrl: wsUrl,
//                                options: AppJoinOptions(role: .host, camera: true))

import Foundation
import AppLoomaCore

/// Roles supported by AppLooma RTC channels.
public enum AppRole: String, Sendable {
    case host, cohost, audience
}

/// Connection lifecycle states.
public enum AppConnectionState: Sendable {
    case connecting, connected, reconnecting, disconnected
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
}

/// Main entry point of the AppLooma RTC SDK.
public final class AppEngine {
    public let appId: String
    public weak var delegate: AppEngineDelegate?

    let room: Room
    private var users: [String: AppRemoteUser] = [:]
    public private(set) var isJoined = false

    private init(appId: String, delegate: AppEngineDelegate?) {
        self.appId = appId
        self.delegate = delegate
        self.room = Room()
        self.room.add(delegate: self)
    }

    /// Create an engine instance with your AppLooma RTC App ID (applooma.dev/dashboard).
    public static func create(appId: String, delegate: AppEngineDelegate? = nil) -> AppEngine {
        precondition(!appId.isEmpty, "AppEngine.create: appId is required")
        return AppEngine(appId: appId, delegate: delegate)
    }

    /// Join a channel with a token from your server
    /// (POST https://api.applooma.dev/v1/token → { token, wsUrl }).
    public func joinChannel(token: String, wsUrl: String, options: AppJoinOptions = AppJoinOptions()) async throws {
        guard !isJoined else { throw AppError.alreadyJoined }
        try await room.connect(url: wsUrl, token: token)
        isJoined = true

        // Participants already in the room when we join never produce a
        // participantDidConnect callback; without this an audience member
        // joining a live stream sees nobody and never receives the host's video.
        seedExistingParticipants()

        if options.role != .audience {
            if options.microphone { try await room.localParticipant.setMicrophone(enabled: true) }
            if options.camera { try await room.localParticipant.setCamera(enabled: true) }
        }
    }

    public func leaveChannel() async {
        await room.disconnect()
        isJoined = false
        users.removeAll()
    }

    /// Announces everyone already present, and their already-published tracks.
    private func seedExistingParticipants() {
        for participant in room.remoteParticipants.values {
            let user = userFor(participant)
            let hasTrack = participant.trackPublications.values.contains { $0.track != nil }
            Task { @MainActor in
                self.delegate?.appEngine(self, userJoined: user)
                if hasTrack { self.delegate?.appEngine(self, trackSubscribedFor: user) }
            }
        }
    }

    // MARK: - Local media controls

    public func enableCamera(_ on: Bool = true) async throws {
        try await room.localParticipant.setCamera(enabled: on)
    }

    public func enableMicrophone(_ on: Bool = true) async throws {
        try await room.localParticipant.setMicrophone(enabled: on)
    }

    /// Broadcast data to the channel (chat, signals, gifts).
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
        users.removeValue(forKey: p.identity?.stringValue ?? "")
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
        Task { @MainActor in self.delegate?.appEngine(self, trackSubscribedFor: user) }
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
