//
// App camera-frame processing: a hook for beauty, filters and other effects
// on the local camera, before the frame is encoded and shown in your own
// preview. The iOS counterpart of Android's `AppEngine.setTextureProcessor`.
//

import Foundation
import AppLoomaCore
import CoreVideo

/// Processes local camera frames. Called on the capture thread for every
/// frame, so it must return quickly (well under one frame interval).
public protocol AppVideoFrameProcessor: AnyObject {
    /// Returns the picture to send: `pixelBuffer` itself to pass it through,
    /// or a new buffer of the same size (32BGRA or 420f/420v NV12).
    /// - Parameters:
    ///   - pixelBuffer: the camera picture as captured, before rotation.
    ///   - rotation: clockwise degrees (0, 90, 180, 270) that make the picture upright.
    ///   - timestamp: capture time in nanoseconds.
    func process(_ pixelBuffer: CVPixelBuffer, rotation: Int, timestamp: Int64) -> CVPixelBuffer
}

/// Runs the built-in enhancement (if on), then the app's processor.
final class AppVideoProcessorChain: NSObject, VideoProcessor {
    private let lock = NSLock()
    private var _enhance: AppVideoEnhanceFilter?
    private var _app: AppVideoFrameProcessor?
    var enhance: AppVideoEnhanceFilter? {
        get { lock.lock(); defer { lock.unlock() }; return _enhance }
        set { lock.lock(); _enhance = newValue; lock.unlock() }
    }
    var app: AppVideoFrameProcessor? {
        get { lock.lock(); defer { lock.unlock() }; return _app }
        set { lock.lock(); _app = newValue; lock.unlock() }
    }

    func process(frame: VideoFrame) -> VideoFrame? {
        var f = frame
        if let e = enhance, let out = e.process(frame: f) { f = out }
        guard let app, let input = (f.buffer as? CVPixelVideoBuffer)?.pixelBuffer else { return f }
        let output = app.process(input, rotation: Int(f.rotation.rawValue), timestamp: f.timeStampNs)
        if output === input { return f }
        return VideoFrame(dimensions: f.dimensions, rotation: f.rotation, timeStampNs: f.timeStampNs, buffer: CVPixelVideoBuffer(pixelBuffer: output))
    }
}

public extension AppEngine {
    /// Sets a processor for the local camera's frames (nil removes it). It runs
    /// after the built-in enhancement, before encoding and the local preview,
    /// and survives camera off/on, switches and republishes. The engine keeps
    /// a strong reference until it is replaced.
    func setVideoProcessor(_ processor: AppVideoFrameProcessor?) {
        videoFrameProcessor = processor
        attachVideoEnhance()
    }

    /// The app's frame processor in force, or nil.
    var videoProcessor: AppVideoFrameProcessor? { videoFrameProcessor }
}
