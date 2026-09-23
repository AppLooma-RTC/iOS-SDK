#if canImport(UIKit)
import SwiftUI
import AppLoomaRTC

@MainActor
final class VoiceModel: RoomModel {
    @Published var joinedAt: [String: Double] = [:]
    @Published var names: [String: String] = [:]
    @Published var mic = true
    @Published var status = "connecting…"
    private var timer: Timer?

    override init(kit: AppLoomaKit, room: String, options: AppEngineOptions) {
        super.init(kit: kit, room: room, options: options)
        joinedAt[kit.user.id] = Date().timeIntervalSince1970 * 1000
        names[kit.user.id] = kit.user.name
    }

    func hello() { send(data: ["kind": "hi", "at": joinedAt[kit.user.id] ?? 0, "name": kit.user.name]) }

    func start() {
        // Picks up remote mute changes that arrive without an event.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick += 1 } }
        Task {
            do {
                try await join(role: "cohost", appRole: .cohost, camera: false, microphone: true)
                for u in engine.remoteUsers { names[u.uid] = u.name }
                add(ChatLine(who: "", text: "You are on a seat — just start talking 🎧", system: true))
                status = "live"
                hello()
            } catch { status = "failed"; add(ChatLine(who: "", text: error.localizedDescription, system: true)) }
        }
    }

    func stop() { timer?.invalidate(); leave() }

    override func userJoined(_ user: AppRemoteUser) {
        super.userJoined(user)
        names[user.uid] = user.name
        add(ChatLine(who: user.name, text: "joined the room", system: true))
        hello()
    }

    override func userLeft(_ user: AppRemoteUser) {
        super.userLeft(user)
        add(ChatLine(who: names[user.uid] ?? user.uid, text: "left", system: true))
        joinedAt[user.uid] = nil
    }

    override func message(_ m: AppMessage) {
        guard let uid = m.from?.uid else { return }
        if m.data?["kind"] as? String == "hi" {
            joinedAt[uid] = (m.data?["at"] as? Double) ?? Double((m.data?["at"] as? Int) ?? 0)
            names[uid] = (m.data?["name"] as? String) ?? uid
        } else if m.data?["kind"] as? String == "wave" {
            add(ChatLine(who: names[uid] ?? uid, text: "waved 👋", system: true))
        } else if let text = m.text {
            add(ChatLine(who: names[uid] ?? uid, text: text))
        }
    }

    var seatOrder: [String] {
        ([kit.user.id] + engine.remoteUsers.map(\.uid)).sorted {
            let a = joinedAt[$0] ?? .infinity, b = joinedAt[$1] ?? .infinity
            return a == b ? $0 < $1 : a < b
        }
    }
}

/// Voice room: seats with a crown for the first speaker, speaking rings, mute
/// badges and room chat. Seat order is join order, agreed between devices with
/// small messages — no server state. Give it the whole screen.
@available(iOS 15.0, *)
public struct AppLoomaVoiceRoomView: View {
    @StateObject private var m: VoiceModel
    private let seats: Int
    private let onLeave: () -> Void
    @State private var say = ""
    @State private var ripple = false

    public init(kit: AppLoomaKit, room: String, seats: Int = 8, onLeave: @escaping () -> Void = {}) {
        _m = StateObject(wrappedValue: VoiceModel(kit: kit, room: room, options: AppEngineOptions(audioScenario: .media)))
        self.seats = min(max(seats, 2), 16)
        self.onLeave = onLeave
    }

    public var body: some View {
        let _ = m.tick
        let order = m.seatOrder
        ZStack {
            LinearGradient(stops: [.init(color: K.hex(0x2C1F66), location: 0), .init(color: K.hex(0x141030), location: 0.4), .init(color: K.ink, location: 1)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: onLeave) { Glass(padding: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)) { Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundColor(K.text) } }.buttonStyle(.plain)
                    Spacer()
                    Glass { Image(systemName: "person.2").font(.system(size: 12)).foregroundColor(K.text); Text("\(order.count)").font(.system(size: 12, weight: .semibold)).foregroundColor(K.text) }
                }.padding(.horizontal, 12).padding(.top, 8)
                VStack(alignment: .leading, spacing: 3) {
                    Text("🎙️ \(m.room)").font(.system(size: 20, weight: .heavy)).foregroundColor(K.text)
                    HStack(spacing: 6) {
                        Circle().fill(K.green).frame(width: 7, height: 7)
                        Text("Voice room · \(m.status)").font(.system(size: 12.5)).foregroundColor(K.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 14)

                seat(0, order: order, big: true).padding(.top, 14)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(1..<seats, id: \.self) { seat($0, order: order) }
                }.padding(.horizontal, 8).padding(.top, 8)

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 6) { ForEach(m.chat) { ChatBubble(line: $0).id($0.id) } }.padding(.horizontal, 16)
                    }
                    .onChange(of: m.chat.count) { _ in if let last = m.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
                }

                HStack(spacing: 10) {
                    TextField("Say hi to the room…", text: $say, onCommit: sendText)
                        .foregroundColor(K.text).padding(.horizontal, 18).frame(height: 46)
                        .background(Capsule().fill(Color.black.opacity(0.35))).overlay(Capsule().stroke(K.line))
                    RoundButton(icon: m.mic ? "mic.fill" : "mic.slash.fill", off: !m.mic) { m.mic.toggle(); let on = m.mic; Task { try? await m.engine.enableMicrophone(on) } }
                    RoundButton(icon: "hand.wave") { m.add(ChatLine(who: m.kit.user.name, text: "waved 👋", system: true)); m.send(data: ["kind": "wave"]) }
                }.padding(12)
            }
        }
        .onAppear {
            m.start()
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { ripple = true }
        }
        .onDisappear { m.stop() }
    }

    @ViewBuilder
    private func seat(_ i: Int, order: [String], big: Bool = false) -> some View {
        let size: CGFloat = big ? 86 : 60
        VStack(spacing: 5) {
            if i < order.count {
                let uid = order[i]
                let name = m.names[uid] ?? uid
                let muted = uid == m.kit.user.id ? !m.mic : !(m.engine.remoteUsers.first { $0.uid == uid }?.audioEnabled ?? true)
                ZStack {
                    if m.speaking.contains(uid) && !muted {
                        Circle().stroke(K.green, lineWidth: 2.5).frame(width: size, height: size)
                            .scaleEffect(ripple ? 1.3 : 1).opacity(ripple ? 0 : 0.9)
                    }
                    Avatar(id: uid, name: name, size: size)
                    if i == 0 { Text("👑").font(.system(size: 18)).offset(y: -size / 2 - 4) }
                    if muted {
                        Image(systemName: "mic.slash.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            .frame(width: 22, height: 22).background(Circle().fill(K.live)).overlay(Circle().stroke(K.ink, lineWidth: 2))
                            .offset(x: size / 2 - 8, y: size / 2 - 8)
                    }
                }.frame(width: size + 16, height: size + 16)
                Text(uid == m.kit.user.id ? "\(name) (you)" : name).font(.system(size: 11.5)).foregroundColor(Color(white: 0.85)).lineLimit(1)
            } else {
                Circle().fill(K.glass).overlay(Circle().strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [4])))
                    .overlay(Image(systemName: "plus").foregroundColor(K.muted)).frame(width: size, height: size).padding(8)
                Text("Seat \(i + 1)").font(.system(size: 10.5)).foregroundColor(K.muted)
            }
        }
    }

    private func sendText() {
        let t = say.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        say = ""
        m.add(ChatLine(who: m.kit.user.name, text: t))
        m.send(text: t)
    }
}
#endif
