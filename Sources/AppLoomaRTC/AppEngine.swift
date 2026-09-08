// AppLooma RTC iOS SDK — main entry point.
// © AppLooma LLC
//
//   let engine = AppEngine.create(appId: "YOUR_APP_ID", delegate: self)
//   try await engine.joinChannel(token: token, wsUrl: wsUrl,
//                                options: AppJoinOptions(role: .host, camera: true))

import Foundation
import LiveKit

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

/// A remote user in the channel.
public final class AppRemoteUser {
    let participant: RemoteParticipant
    init(_ p: RemoteParticipant) { participant = p }

    public var uid: String { participant.identity?.stringValue ?? "" }
    public var displayName: String? { participant.name }
    public var metadata: String? { participant.metadata }
    public var isSpeaking: Bool { participant.isSpeaking }

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
    func appEngine(_ engine: AppEngine, dataReceived data: Data, from user: AppRemoteUser?)
    func appEngine(_ engine: AppEngine, giftReceived gift: AppGiftEvent)
}

// Default empty implementations so integrators override only what they need.
public extension AppEngineDelegate {
    func appEngine(_ engine: AppEngine, userJoined user: AppRemoteUser) {}
    func appEngine(_ engine: AppEngine, userLeft user: AppRemoteUser) {}
    func appEngine(_ engine: AppEngine, trackSubscribedFor user: AppRemoteUser) {}
    func appEngine(_ engine: AppEngine, connectionStateChanged state: AppConnectionState) {}
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
    public func sendData(_ data: Data, reliable: Bool = true) async throws {
        try await room.localParticipant.publish(data: data, options: DataPublishOptions(reliable: reliable))
    }

    // MARK: - State

    public var localUid: String { room.localParticipant.identity?.stringValue ?? "" }
    public var channelName: String { room.name ?? "" }
    public var remoteUsers: [AppRemoteUser] { Array(users.values) }

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
    public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let user = userFor(participant)
        Task { @MainActor in self.delegate?.appEngine(self, userJoined: user) }
    }

    public func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard let user = removeUser(participant) else { return }
        Task { @MainActor in self.delegate?.appEngine(self, userLeft: user) }
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
        let gift = AppGiftEvent.tryParse(data)
        Task { @MainActor in
            self.delegate?.appEngine(self, dataReceived: data, from: user)
            if let gift { self.delegate?.appEngine(self, giftReceived: gift) }
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
