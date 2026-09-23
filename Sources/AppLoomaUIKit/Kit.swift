// AppLooma RTC UIKit for SwiftUI — drop-in live streaming, voice room and 1-to-1 call screens.
// © AppLooma LLC
//
//   let kit = AppLoomaKit(appId: "YOUR_APP_ID", user: KitUser(id: me.id, name: me.name)) { room, role, user in
//       let r = try await myAPI.rtcToken(room: room, role: role)   // YOUR server
//       return KitToken(token: r.token, wsUrl: r.wsUrl)
//   }
//   AppLoomaLiveStreamView(kit: kit, room: "show-42", role: .host) { dismiss() }

#if canImport(UIKit)
import SwiftUI
import AppLoomaRTC

/// Who is using the kit. `id` must be unique in the room; `name` is shown to others.
public struct KitUser: Sendable {
    public let id: String
    public let name: String
    public let avatarURL: URL?
    public init(id: String, name: String, avatarURL: URL? = nil) {
        self.id = id; self.name = name; self.avatarURL = avatarURL
    }
}

/// A token from YOUR server. The API secret never reaches the app.
public struct KitToken: Sendable {
    public let token: String
    public let wsUrl: String
    public init(token: String, wsUrl: String) { self.token = token; self.wsUrl = wsUrl }
}

/// What every kit screen needs: your App ID, the signed-in user and a way to get tokens.
/// Put `{ "name": … }` in the token metadata so others see the user's name.
public struct AppLoomaKit {
    public let appId: String
    public let user: KitUser
    public let tokenProvider: (_ room: String, _ role: String, _ user: KitUser) async throws -> KitToken
    public init(appId: String, user: KitUser, tokenProvider: @escaping (_ room: String, _ role: String, _ user: KitUser) async throws -> KitToken) {
        self.appId = appId; self.user = user; self.tokenProvider = tokenProvider
    }
}

// MARK: - Design system

enum K {
    static let ink = Color(red: 7 / 255, green: 7 / 255, blue: 13 / 255)
    static let glass = Color.white.opacity(0.07)
    static let glass2 = Color.white.opacity(0.12)
    static let line = Color.white.opacity(0.09)
    static let text = Color(red: 245 / 255, green: 245 / 255, blue: 250 / 255)
    static let muted = Color(red: 154 / 255, green: 154 / 255, blue: 176 / 255)
    static let violet = Color(red: 124 / 255, green: 92 / 255, blue: 255 / 255)
    static let pink = Color(red: 255 / 255, green: 79 / 255, blue: 163 / 255)
    static let live = Color(red: 255 / 255, green: 59 / 255, blue: 92 / 255)
    static let gold = Color(red: 255 / 255, green: 194 / 255, blue: 75 / 255)
    static let green = Color(red: 46 / 255, green: 229 / 255, blue: 157 / 255)
    static let brand = LinearGradient(colors: [violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)

    private static let pairs: [(UInt32, UInt32)] = [
        (0x7C5CFF, 0xFF4FA3), (0x13B58A, 0x0E6F78), (0xFF9A3C, 0xFF4F7A), (0x3C8DFF, 0x7C5CFF),
        (0xFF4F7A, 0xFFC24B), (0x00C2D1, 0x2EE59D), (0xB04BFF, 0x5A3CFF), (0xFF6B3C, 0xFF3B5C),
    ]
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    static func gradient(for key: String) -> LinearGradient {
        var h: UInt32 = 0
        for u in key.unicodeScalars { h = (h &* 31 &+ u.value) & 0x7FFF_FFFF }
        let p = pairs[Int(h) % pairs.count]
        return LinearGradient(colors: [hex(p.0), hex(p.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct Avatar: View {
    let id: String
    let name: String
    var size: CGFloat = 36
    var body: some View {
        Circle().fill(K.gradient(for: id))
            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1.5))
            .overlay(Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .heavy)).foregroundColor(.white))
            .frame(width: size, height: size)
    }
}

struct Glass<Content: View>: View {
    var padding = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 5) { content() }
            .padding(padding)
            .background(Capsule().fill(Color.black.opacity(0.38)))
            .overlay(Capsule().stroke(K.line, lineWidth: 1))
    }
}

/// Round control: soft glass, white when "off", red for end, gradient for brand.
struct RoundButton: View {
    let icon: String
    var size: CGFloat = 50
    var off = false
    var danger = false
    var brand = false
    var tint: Color = .white
    var label: String?
    let action: () -> Void
    var body: some View {
        VStack(spacing: 7) {
            Button(action: action) {
                ZStack {
                    if off { Circle().fill(Color.white) }
                    else if danger { Circle().fill(K.live).shadow(color: K.live.opacity(0.45), radius: 12, y: 8) }
                    else if brand { Circle().fill(K.brand) }
                    else { Circle().fill(K.glass2) }
                    Image(systemName: icon).font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundColor(off ? Color(white: 0.07) : tint)
                }
                .frame(width: size, height: size)
            }
            .buttonStyle(.plain)
            if let label { Text(label).font(.system(size: 11.5)).foregroundColor(Color(white: 0.82)) }
        }
    }
}

struct ChatLine: Identifiable {
    let id = UUID()
    let who: String
    let text: String
    var system = false
    var gift = false
}

struct ChatBubble: View {
    let line: ChatLine
    var body: some View {
        (Text(line.who.isEmpty ? "" : line.who + "  ").foregroundColor(K.gold).fontWeight(.bold)
         + Text(line.text).foregroundColor(line.system ? K.muted : K.text))
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(
                Group {
                    if line.gift {
                        RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [K.gold.opacity(0.35), K.pink.opacity(0.25)], startPoint: .leading, endPoint: .trailing))
                    } else {
                        RoundedRectangle(cornerRadius: 14).fill(Color.black.opacity(0.35))
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Shade: View {
    let top: Bool
    var body: some View {
        LinearGradient(colors: top ? [Color.black.opacity(0.55), .clear] : [.clear, Color.black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }
}

/// A remote user's camera, or your own when `user` is nil.
struct VideoTile: UIViewRepresentable {
    let engine: AppEngine
    let user: AppRemoteUser?
    func makeUIView(context: Context) -> AppVideoView {
        let v = AppVideoView()
        v.contentMode = .scaleAspectFill
        if let user { v.attach(user: user) } else { v.attachLocal(engine: engine) }
        return v
    }
    func updateUIView(_ v: AppVideoView, context: Context) {
        if let user { v.attach(user: user) }
    }
}

extension AppRemoteUser {
    var name: String { (attributes["name"] as? String) ?? uid }
}

func formatTime(_ sec: Int) -> String { String(format: "%02d:%02d", sec / 60, sec % 60) }

/// Shared engine plumbing for every screen: owns the engine, republishes its
/// events as SwiftUI state.
@MainActor
class RoomModel: ObservableObject, AppEngineDelegate {
    let kit: AppLoomaKit
    let room: String
    let engine: AppEngine
    @Published var tick = 0
    @Published var chat: [ChatLine] = []
    @Published var speaking: Set<String> = []

    init(kit: AppLoomaKit, room: String, options: AppEngineOptions) {
        self.kit = kit
        self.room = room
        self.engine = AppEngine.create(appId: kit.appId, options: options)
        self.engine.delegate = self
    }

    func add(_ l: ChatLine, max: Int = 50) {
        chat.append(l)
        if chat.count > max { chat.removeFirst(chat.count - max) }
    }

    func join(role: String, appRole: AppRole, camera: Bool, microphone: Bool) async throws {
        let t = try await kit.tokenProvider(room, role, kit.user)
        try await engine.joinChannel(token: t.token, wsUrl: t.wsUrl, options: AppJoinOptions(role: appRole, camera: camera, microphone: microphone))
        tick += 1
    }

    func send(text: String? = nil, data: [String: Any]? = nil, reliable: Bool = true) {
        Task { _ = try? await engine.sendMessage(text: text, data: data, reliable: reliable) }
    }

    func leave() { Task { await engine.leaveChannel() } }

    // Default delegate plumbing: any change re-renders.
    nonisolated func appEngine(_ engine: AppEngine, userJoined user: AppRemoteUser) { Task { @MainActor in self.userJoined(user) } }
    nonisolated func appEngine(_ engine: AppEngine, userLeft user: AppRemoteUser) { Task { @MainActor in self.userLeft(user) } }
    nonisolated func appEngine(_ engine: AppEngine, trackSubscribedFor user: AppRemoteUser) { Task { @MainActor in self.tick += 1 } }
    nonisolated func appEngine(_ engine: AppEngine, userMediaChangedFor user: AppRemoteUser) { Task { @MainActor in self.tick += 1 } }
    nonisolated func appEngine(_ engine: AppEngine, audienceChanged audience: [AppRemoteUser]) { Task { @MainActor in self.tick += 1 } }
    nonisolated func appEngine(_ engine: AppEngine, activeSpeakersChanged uids: [String]) { Task { @MainActor in self.speaking = Set(uids) } }
    nonisolated func appEngine(_ engine: AppEngine, messageReceived message: AppMessage) { Task { @MainActor in self.message(message) } }
    nonisolated func appEngine(_ engine: AppEngine, remoteStats stats: [AppRemoteStats]) { Task { @MainActor in self.stats(stats) } }

    func userJoined(_ user: AppRemoteUser) { tick += 1 }
    func userLeft(_ user: AppRemoteUser) { tick += 1 }
    func message(_ m: AppMessage) {}
    func stats(_ s: [AppRemoteStats]) {}
}
#endif
