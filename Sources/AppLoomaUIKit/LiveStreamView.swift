#if canImport(UIKit)
import SwiftUI
import AppLoomaRTC

/// Who starts the live stream and who watches it.
public enum KitLiveRole { case host, audience }

private let gifts = [("🌹", "Rose"), ("💎", "Diamond"), ("🚀", "Rocket"), ("👑", "Crown")]

@MainActor
final class LiveModel: RoomModel {
    @Published var isHost = true
    @Published var joined = false
    @Published var joining = false
    @Published var mic = true
    @Published var cam = true
    @Published var banner: (from: String, name: String, emoji: String)?
    @Published var hearts: [Heart] = []

    struct Heart: Identifiable { let id = UUID(); let dx: CGFloat; let emoji: String }

    func start() {
        guard !joining, !joined else { return }
        joining = true
        Task {
            do {
                try await join(role: isHost ? "host" : "audience", appRole: isHost ? .host : .audience, camera: isHost, microphone: isHost)
                add(ChatLine(who: "", text: "Welcome! Be kind in the chat 💬", system: true))
                joined = true
            } catch { add(ChatLine(who: "", text: error.localizedDescription, system: true)) }
            joining = false
        }
    }

    func heart() {
        let h = Heart(dx: CGFloat.random(in: -30...30), emoji: ["💖", "💜", "💗", "✨", "🔥"].randomElement()!)
        hearts.append(h)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { [weak self] in self?.hearts.removeAll { $0.id == h.id } }
    }

    func gift(from: String, index: Int) {
        let g = gifts[index % gifts.count]
        add(ChatLine(who: from, text: "sent \(g.1) \(g.0)", gift: true))
        banner = (from, g.1, g.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in self?.banner = nil }
    }

    override func userJoined(_ user: AppRemoteUser) {
        super.userJoined(user)
        if !user.isPublisher { add(ChatLine(who: user.name, text: "joined", system: true)) }
    }

    override func message(_ m: AppMessage) {
        let from = m.from?.name ?? "Someone"
        if let text = m.text { add(ChatLine(who: from, text: text)) }
        else if m.data?["kind"] as? String == "like" { heart() }
        else if m.data?["kind"] as? String == "gift" { gift(from: from, index: (m.data?["i"] as? Int) ?? 0) }
    }
}

/// Live streaming screen: host camera, chat, hearts, gifts, viewer count.
/// Give it the whole screen.
@available(iOS 15.0, *)
public struct AppLoomaLiveStreamView: View {
    @StateObject private var m: LiveModel
    private let fixedRole: KitLiveRole?
    private let onLeave: () -> Void
    @State private var say = ""

    /// - Parameter role: `.host` goes live straight away, `.audience` watches. Nil lets the user choose.
    public init(kit: AppLoomaKit, room: String, role: KitLiveRole? = nil, onLeave: @escaping () -> Void = {}) {
        _m = StateObject(wrappedValue: LiveModel(kit: kit, room: room, options: AppEngineOptions(audioScenario: .media, video: AppVideoConfig(height: 720, fps: 30))))
        fixedRole = role
        self.onLeave = onLeave
    }

    public var body: some View {
        let _ = m.tick
        let host = m.engine.hosts.first
        let showVideo = m.joined && (m.isHost ? m.cam : (host?.hasVideo ?? false))
        let hostName = m.isHost ? m.kit.user.name : (host?.name ?? "—")
        ZStack {
            Color.black.ignoresSafeArea()
            if showVideo {
                VideoTile(engine: m.engine, user: m.isHost ? nil : host).id(m.isHost ? "me" : host?.uid ?? "").ignoresSafeArea()
            } else {
                RadialGradient(colors: [K.hex(0x2A1F5A), K.ink], center: .center, startRadius: 0, endRadius: 500).ignoresSafeArea()
                VStack(spacing: 8) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 30)).foregroundColor(K.muted)
                    Text(!m.joined ? "Live · \(m.room)" : m.isHost ? "Camera is off" : "Waiting for the host…").foregroundColor(K.muted)
                }
            }
            VStack(spacing: 0) {
                Shade(top: true).frame(height: 140)
                Spacer()
                Shade(top: false).frame(height: 340)
            }.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar(hostName: hostName, hostId: m.isHost ? m.kit.user.id : host?.uid ?? m.room)
                if let b = m.banner { giftBanner(b).padding(.top, 6) }
                Spacer()
                ZStack(alignment: .bottomTrailing) {
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 6) { ForEach(m.chat) { ChatBubble(line: $0).id($0.id) } }
                        }
                        .frame(maxHeight: 240)
                        .onChange(of: m.chat.count) { _ in if let last = m.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                    }
                    .padding(.leading, 12).padding(.trailing, 90)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(m.hearts) { FloatingHeart(heart: $0) }
                    if m.joined && m.isHost {
                        VStack(spacing: 12) {
                            RoundButton(icon: m.mic ? "mic.fill" : "mic.slash.fill", off: !m.mic) { m.mic.toggle(); let on = m.mic; Task { try? await m.engine.enableMicrophone(on) } }
                            RoundButton(icon: m.cam ? "video.fill" : "video.slash.fill", off: !m.cam) { m.cam.toggle(); let on = m.cam; Task { try? await m.engine.enableCamera(on) } }
                            RoundButton(icon: "arrow.triangle.2.circlepath.camera") { Task { try? await m.engine.switchCamera() } }
                        }.padding(.trailing, 12)
                    }
                }
                if m.joined { bottomBar } else { prejoin }
            }
        }
        .onAppear { if let r = fixedRole { m.isHost = r == .host; m.start() } }
        .onDisappear { m.leave() }
    }

    private func topBar(hostName: String, hostId: String) -> some View {
        HStack(spacing: 8) {
            Glass(padding: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 12)) {
                Avatar(id: hostId, name: hostName, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.joined ? hostName : "—").font(.system(size: 13, weight: .bold)).foregroundColor(K.text)
                    Text(m.isHost && m.joined ? "You are live" : "Live").font(.system(size: 11)).foregroundColor(K.muted)
                }.padding(.leading, 4)
            }
            if m.joined {
                Text("LIVE").font(.system(size: 11, weight: .heavy)).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 7).fill(K.live))
            }
            Spacer()
            Glass {
                Image(systemName: "eye").font(.system(size: 13)).foregroundColor(K.text)
                Text("\(m.engine.audienceCount + (m.isHost || !m.joined ? 0 : 1))").font(.system(size: 12, weight: .semibold)).foregroundColor(K.text)
            }
            Button(action: onLeave) { Glass(padding: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)) { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(K.text) } }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func giftBanner(_ b: (from: String, name: String, emoji: String)) -> some View {
        HStack(spacing: 10) {
            Avatar(id: b.from, name: b.from, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.from).font(.system(size: 13, weight: .heavy))
                Text("sent \(b.name)").font(.system(size: 12))
            }.foregroundColor(K.hex(0x1A0F00))
            Text(b.emoji).font(.system(size: 28))
        }
        .padding(.leading, 6).padding(.trailing, 16).padding(.vertical, 6)
        .background(Capsule().fill(LinearGradient(colors: [K.gold, K.pink], startPoint: .leading, endPoint: .trailing)))
        .shadow(color: K.gold.opacity(0.4), radius: 14, y: 8)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 12)
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            TextField("Say something…", text: $say, onCommit: sendText)
                .foregroundColor(K.text).padding(.horizontal, 18).frame(height: 46)
                .background(Capsule().fill(Color.black.opacity(0.35))).overlay(Capsule().stroke(K.line))
            RoundButton(icon: "gift.fill", tint: K.gold) { let i = Int.random(in: 0..<gifts.count); m.gift(from: m.kit.user.name, index: i); m.send(data: ["kind": "gift", "i": i]) }
            RoundButton(icon: "heart.fill", brand: true) { m.heart(); m.send(data: ["kind": "like"], reliable: false) }
        }
        .padding(12)
    }

    private var prejoin: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                seg("Go live", on: m.isHost) { m.isHost = true }
                seg("Watch", on: !m.isHost) { m.isHost = false }
            }
            .padding(5).background(RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.45)))
            Button(action: m.start) {
                Text(m.joining ? "Connecting…" : m.isHost ? "Start broadcast" : "Join as viewer")
                    .font(.system(size: 15.5, weight: .bold)).foregroundColor(.white)
                    .frame(maxWidth: .infinity).frame(height: 54)
                    .background(RoundedRectangle(cornerRadius: 16).fill(K.brand))
            }.buttonStyle(.plain)
        }
        .padding(20)
    }

    private func seg(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 14, weight: .bold)).foregroundColor(on ? .white : K.muted)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(RoundedRectangle(cornerRadius: 12).fill(on ? AnyShapeStyle(K.brand) : AnyShapeStyle(Color.clear)))
        }.buttonStyle(.plain)
    }

    private func sendText() {
        let t = say.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        say = ""
        m.add(ChatLine(who: m.kit.user.name, text: t))
        m.send(text: t)
    }
}

@available(iOS 15.0, *)
private struct FloatingHeart: View {
    let heart: LiveModel.Heart
    @State private var t: CGFloat = 0
    var body: some View {
        Text(heart.emoji).font(.system(size: 28))
            .scaleEffect(0.6 + 0.5 * (t < 0.15 ? t / 0.15 : 1 - t * 0.3))
            .opacity(Double(t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85))
            .offset(x: heart.dx * t, y: -280 * t)
            .padding(.trailing, 22).padding(.bottom, 150)
            .onAppear { withAnimation(.easeOut(duration: 2.2)) { t = 1 } }
    }
}
#endif
