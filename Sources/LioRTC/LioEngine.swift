// Lio Live iOS SDK — main entry point.
// © AppLooma LLC
//
//   let engine = LioEngine.create(appId: "YOUR_APP_ID", delegate: self)
//   try await engine.joinChannel(token: token, wsUrl: wsUrl,
//                                options: LioJoinOptions(role: .host, camera: true))

import Foundation
import LiveKit

/// Roles supported by Lio Live channels.
public enum LioRole: String, Sendable {
    case host, cohost, audience
}

/// Connection lifecycle states.
public enum LioConnectionState: Sendable {
    case connecting, connected, reconnecting, disconnected
}

/// Options for joining a channel.
public struct LioJoinOptions: Sendable {
    public var role: LioRole
    /// Auto-enable camera on join (ignored for audience).
    public var camera: Bool
    /// Auto-enable microphone on join (ignored for audience).
    public var microphone: Bool

    public init(role: LioRole = .host, camera: Bool = false, microphone: Bool = true) {
        self.role = role
        self.camera = camera
        self.microphone = microphone
    }
}

/// A remote user in the channel.
public final class LioRemoteUser {
    let participant: RemoteParticipant
    init(_ p: RemoteParticipant) { participant = p }

    public var uid: String { participant.identity?.stringValue ?? "" }
    public var displayName: String? { participant.name }
    public var metadata: String? { participant.metadata }
    public var isSpeaking: Bool { participant.isSpeaking }

    /// First available video track for rendering with `LioVideoView`.
    public var videoTrack: VideoTrack? {
        participant.videoTracks.compactMap { $0.track as? VideoTrack }.first
    }

    /// internal — escape hatch for UIKits
    public var raw: RemoteParticipant { participant }
}

/// Channel event callbacks. All delivered on the main actor.
public protocol LioEngineDelegate: AnyObject {
    func lioEngine(_ engine: LioEngine, userJoined user: LioRemoteUser)
    func lioEngine(_ engine: LioEngine, userLeft user: LioRemoteUser)
    func lioEngine(_ engine: LioEngine, trackSubscribedFor user: LioRemoteUser)
    func lioEngine(_ engine: LioEngine, connectionStateChanged state: LioConnectionState)
    func lioEngine(_ engine: LioEngine, dataReceived data: Data, from user: LioRemoteUser?)
}

// Default empty implementations so integrators override only what they need.
public extension LioEngineDelegate {
    func lioEngine(_ engine: LioEngine, userJoined user: LioRemoteUser) {}
    func lioEngine(_ engine: LioEngine, userLeft user: LioRemoteUser) {}
    func lioEngine(_ engine: LioEngine, trackSubscribedFor user: LioRemoteUser) {}
    func lioEngine(_ engine: LioEngine, connectionStateChanged state: LioConnectionState) {}
    func lioEngine(_ engine: LioEngine, dataReceived data: Data, from user: LioRemoteUser?) {}
}

/// Main entry point of the Lio Live SDK.
public final class LioEngine {
    public let appId: String
    public weak var delegate: LioEngineDelegate?

    let room: Room
    private var users: [String: LioRemoteUser] = [:]
    public private(set) var isJoined = false

    private init(appId: String, delegate: LioEngineDelegate?) {
        self.appId = appId
        self.delegate = delegate
        self.room = Room()
        self.room.add(delegate: self)
    }

    /// Create an engine instance with your Lio Live App ID (console.liolive.com).
    public static func create(appId: String, delegate: LioEngineDelegate? = nil) -> LioEngine {
        precondition(!appId.isEmpty, "LioEngine.create: appId is required")
        return LioEngine(appId: appId, delegate: delegate)
    }

    /// Join a channel with a token from your server
    /// (POST https://api.liolive.com/v1/token → { token, wsUrl }).
    public func joinChannel(token: String, wsUrl: String, options: LioJoinOptions = LioJoinOptions()) async throws {
        guard !isJoined else { throw LioError.alreadyJoined }
        try await room.connect(url: wsUrl, token: token)
        isJoined = true
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
    public var remoteUsers: [LioRemoteUser] { Array(users.values) }

    /// Local camera track for preview rendering.
    public var localVideoTrack: VideoTrack? {
        room.localParticipant.videoTracks.compactMap { $0.track as? VideoTrack }.first
    }

    /// internal — escape hatch for UIKits
    public var raw: Room { room }

    func userFor(_ p: RemoteParticipant) -> LioRemoteUser {
        let key = p.identity?.stringValue ?? ""
        if let existing = users[key] { return existing }
        let u = LioRemoteUser(p)
        users[key] = u
        return u
    }

    func removeUser(_ p: RemoteParticipant) -> LioRemoteUser? {
        users.removeValue(forKey: p.identity?.stringValue ?? "")
    }
}

public enum LioError: Error {
    case alreadyJoined
}

// MARK: - RoomDelegate bridge

extension LioEngine: RoomDelegate {
    public func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let user = userFor(participant)
        Task { @MainActor in self.delegate?.lioEngine(self, userJoined: user) }
    }

    public func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        guard let user = removeUser(participant) else { return }
        Task { @MainActor in self.delegate?.lioEngine(self, userLeft: user) }
    }

    public func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let user = userFor(participant)
        Task { @MainActor in self.delegate?.lioEngine(self, trackSubscribedFor: user) }
    }

    public func room(_ room: Room, didUpdateConnectionState state: ConnectionState, from oldState: ConnectionState) {
        let mapped: LioConnectionState
        switch state {
        case .connecting: mapped = .connecting
        case .connected: mapped = .connected
        case .reconnecting: mapped = .reconnecting
        default: mapped = .disconnected
        }
        if case .disconnected = state { isJoined = false }
        Task { @MainActor in self.delegate?.lioEngine(self, connectionStateChanged: mapped) }
    }

    public func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        let user = participant.map { userFor($0) }
        Task { @MainActor in self.delegate?.lioEngine(self, dataReceived: data, from: user) }
    }
}
