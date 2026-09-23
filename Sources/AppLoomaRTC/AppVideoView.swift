// AppLooma RTC iOS SDK — video rendering.
// © AppLooma LLC

#if canImport(UIKit)
import UIKit
import AppLoomaCore

/// Renders a AppLooma video track (local preview or remote user).
///
/// A view attached with `attachLocal` follows your camera through every
/// restart — off/on, a camera switch, a settings change — so a self-preview
/// never stays stuck on the last frame of a track that is gone.
public final class AppVideoView: UIView {
    private let videoView = VideoView()
    private weak var localEngine: AppEngine?

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.bottomAnchor.constraint(equalTo: bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// The track to render. Set nil to clear. Setting this directly detaches
    /// the view from any engine it was following as a self-preview.
    public var track: VideoTrack? {
        get { videoView.track as? VideoTrack }
        set {
            localEngine?.localViews.remove(self)
            localEngine = nil
            videoView.track = newValue
        }
    }

    /// Mirror the video (use for local front-camera preview).
    public var isMirrored: Bool {
        get { videoView.mirrorMode == .mirror }
        set { videoView.mirrorMode = newValue ? .mirror : .off }
    }

    /// Show a remote user's video.
    public func attach(user: AppRemoteUser) { track = user.videoTrack }

    /// Show the local camera preview. The view re-binds by itself whenever the
    /// engine's camera track is replaced; call `refreshLocal` only if you
    /// bypass the engine's own controls.
    public func attachLocal(engine: AppEngine) {
        localEngine?.localViews.remove(self)
        localEngine = engine
        engine.localViews.add(self)
        videoView.track = engine.localVideoTrack
        isMirrored = true
    }

    /// Re-read the engine's current camera track. Called by the engine on every
    /// local track change; harmless to call yourself.
    public func refreshLocal(engine: AppEngine) {
        let current = engine.localVideoTrack
        if videoView.track !== current { videoView.track = current }
    }

    deinit { localEngine?.localViews.remove(self) }
}
#endif
