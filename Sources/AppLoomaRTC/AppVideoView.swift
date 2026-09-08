// AppLooma RTC iOS SDK — video rendering.
// © AppLooma LLC

#if canImport(UIKit)
import UIKit
import LiveKit

/// Renders a AppLooma video track (local preview or remote user).
public final class AppVideoView: UIView {
    private let videoView = VideoView()

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

    /// The track to render. Set nil to clear.
    public var track: VideoTrack? {
        get { videoView.track as? VideoTrack }
        set { videoView.track = newValue }
    }

    /// Mirror the video (use for local front-camera preview).
    public var isMirrored: Bool {
        get { videoView.mirrorMode == .mirror }
        set { videoView.mirrorMode = newValue ? .mirror : .off }
    }

    /// Show a remote user's video.
    public func attach(user: AppRemoteUser) { track = user.videoTrack }

    /// Show the local camera preview.
    public func attachLocal(engine: AppEngine) {
        track = engine.localVideoTrack
        isMirrored = true
    }
}
#endif
