#if canImport(UIKit)
import SwiftUI
import AppLoomaRTC

@MainActor
final class CallModel: RoomModel {
    let video: Bool
    @Published var peer: AppRemoteUser?
    @Published var startedAt: Date?
    @Published var status = "Connecting…"
    @Published var quality = "HD"
    @Published var mic = true
    @Published var cam = true
    @Published var ended = false
    private var timer: Timer?

    init(kit: AppLoomaKit, room: String, video: Bool) {
        self.video = video
        // A private voice call belongs on the call path: earpiece, speech-tuned echo cancelling.
        super.init(kit: kit, room: room, options: AppEngineOptions(audioScenario: video ? .media : .call, video: AppVideoConfig(height: 720, fps: 30)))
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in if self?.startedAt != nil { self?.tick += 1 } } }
        Task {
            do {
                try await join(role: "host", appRole: .host, camera: video, microphone: true)
                status = "Calling…"
                engine.remoteUsers.forEach(meet)
            } catch { status = error.localizedDescription }
        }
    }

    func stop() { timer?.invalidate(); leave() }

    func meet(_ u: AppRemoteUser) {
        if peer == nil { peer = u }
        if startedAt == nil { startedAt = Date() }
        tick += 1
    }

    override func userJoined(_ user: AppRemoteUser) { meet(user) }
    nonisolated override func appEngine(_ engine: AppEngine, trackSubscribedFor user: AppRemoteUser) { Task { @MainActor in self.meet(user) } }
    override func userLeft(_ user: AppRemoteUser) {
        guard user.uid == peer?.uid else { return }
        peer = nil; startedAt = nil; status = "Call ended"; ended = true
    }
    override func stats(_ s: [AppRemoteStats]) {
        guard let x = s.first else { return }
        quality = video && x.videoHeight > 0 ? "\(x.videoHeight)p" : (x.audioPacketsLost > 50 ? "Weak" : "HD")
    }
}

/// 1-to-1 call, voice or video: pulsing avatar and timer, full-screen remote
/// video with a draggable self-view, mute / camera / flip / end. Both people
/// open the same room; the second to arrive connects the call.
@available(iOS 15.0, *)
public struct AppLoomaCallView: View {
    @StateObject private var m: CallModel
    private let onLeave: () -> Void
    @State private var pulse = false
    @State private var pip: CGSize = .zero
    @State private var pipBase: CGSize = .zero

    public init(kit: AppLoomaKit, room: String, video: Bool = true, onLeave: @escaping () -> Void = {}) {
        _m = StateObject(wrappedValue: CallModel(kit: kit, room: room, video: video))
        self.onLeave = onLeave
    }

    public var body: some View {
        let _ = m.tick
        let peer = m.peer
        let name = peer?.name ?? m.status
        let showRemote = m.video && (peer?.hasVideo ?? false)
        let elapsed = m.startedAt.map { formatTime(Int(Date().timeIntervalSince($0))) }
        ZStack {
            Color.black.ignoresSafeArea()
            if showRemote, let peer {
                VideoTile(engine: m.engine, user: peer).id(peer.uid).ignoresSafeArea()
                VStack { Shade(top: true).frame(height: 140); Spacer() }.ignoresSafeArea()
            } else {
                RadialGradient(colors: [K.hex(0x1D3A4D), K.ink], center: .center, startRadius: 0, endRadius: 500).ignoresSafeArea()
                VStack(spacing: 8) {
                    ZStack {
                        ForEach([0.0, 0.5], id: \.self) { phase in
                            Circle().fill(K.green.opacity(0.18)).frame(width: 132, height: 132)
                                .scaleEffect(pulse ? 1.7 : 1 + phase * 0.3).opacity(pulse ? 0 : 1 - phase * 0.5)
                        }
                        Avatar(id: peer?.uid ?? m.room, name: peer == nil ? "…" : name, size: 132)
                    }.frame(width: 220, height: 220)
                    Text(name).font(.system(size: 26, weight: .heavy)).foregroundColor(K.text)
                    Text(elapsed ?? "Waiting for the other person…").font(.system(size: 15).monospacedDigit()).foregroundColor(K.muted)
                }
            }

            VStack {
                HStack(spacing: 8) {
                    Button(action: onLeave) { Glass(padding: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)) { Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundColor(K.text) } }.buttonStyle(.plain)
                    Spacer()
                    if showRemote, let elapsed { Glass { Text(elapsed).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundColor(K.text) } }
                    Glass { Image(systemName: "cellularbars").font(.system(size: 12)).foregroundColor(K.green); Text(m.quality).font(.system(size: 12, weight: .semibold)).foregroundColor(K.text) }
                }.padding(.horizontal, 12).padding(.top, 8)
                Spacer()
                HStack(alignment: .top) {
                    Spacer()
                    RoundButton(icon: m.mic ? "mic.fill" : "mic.slash.fill", off: !m.mic, label: "Mute") { m.mic.toggle(); let on = m.mic; Task { try? await m.engine.enableMicrophone(on) } }
                    Spacer()
                    if m.video {
                        RoundButton(icon: m.cam ? "video.fill" : "video.slash.fill", off: !m.cam, label: "Camera") { m.cam.toggle(); let on = m.cam; Task { try? await m.engine.enableCamera(on) } }
                        Spacer()
                    }
                    RoundButton(icon: "phone.down.fill", size: 66, danger: true, label: "End", action: onLeave)
                    Spacer()
                    if m.video {
                        RoundButton(icon: "arrow.triangle.2.circlepath.camera", label: "Flip") { Task { try? await m.engine.switchCamera() } }
                        Spacer()
                    }
                }
                .padding(.top, 30).padding(.bottom, 20)
                .background(LinearGradient(colors: [.clear, Color.black.opacity(0.7)], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            }

            if m.video && m.cam {
                VideoTile(engine: m.engine, user: nil)
                    .frame(width: 108, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.3), lineWidth: 2))
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 12)
                    .offset(pip)
                    .gesture(DragGesture()
                        .onChanged { pip = CGSize(width: pipBase.width + $0.translation.width, height: pipBase.height + $0.translation.height) }
                        .onEnded { _ in pipBase = pip })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 60).padding(.trailing, 14)
            }
        }
        .onAppear {
            m.start()
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .onDisappear { m.stop() }
        .onChange(of: m.ended) { ended in if ended { DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: onLeave) } }
    }
}
#endif
