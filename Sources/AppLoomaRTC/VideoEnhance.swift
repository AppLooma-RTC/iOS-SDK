//
// Built-in camera enhancement: skin smoothing, low-light boost, sharpening
// and warmth, done with Core Image on the capture path (before the frame is
// encoded and shown in your own preview).
//

import Foundation
import AppLoomaCore
import CoreImage
import CoreVideo

/// Options for `AppEngine.setVideoEnhance(_:)`.
public struct AppVideoEnhance: Equatable, Sendable {
    /// Skin smoothing, 0 (off) to 1. Edge-preserving, with a slight brightness lift.
    public var beauty: Float
    /// Brighten dark scenes adaptively.
    public var lowLight: Bool
    /// Detail boost, 0 (off) to 1.
    public var sharpen: Float
    /// Colour temperature, -1 (cooler) to 1 (warmer).
    public var warmth: Float

    public init(beauty: Float = 0, lowLight: Bool = false, sharpen: Float = 0, warmth: Float = 0) {
        self.beauty = beauty.isFinite ? min(max(beauty, 0), 1) : 0
        self.lowLight = lowLight
        self.sharpen = sharpen.isFinite ? min(max(sharpen, 0), 1) : 0
        self.warmth = warmth.isFinite ? min(max(warmth, -1), 1) : 0
    }

    /// True when these options would change nothing.
    public var isNeutral: Bool { beauty == 0 && !lowLight && sharpen == 0 && warmth == 0 }

    /// A good default for a front camera: gentle smoothing plus low-light help.
    public static let portrait = AppVideoEnhance(beauty: 0.5, lowLight: true)
}

/// The Core Image filter chain behind `AppVideoEnhance`. Attached to the
/// camera capturer as its frame processor.
final class AppVideoEnhanceFilter: NSObject, VideoProcessor {
    private let lock = NSLock()
    private var _options: AppVideoEnhance
    var options: AppVideoEnhance {
        get { lock.lock(); defer { lock.unlock() }; return _options }
        set { lock.lock(); _options = newValue; lock.unlock() }
    }

    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    private var pool: CVPixelBufferPool?
    private var poolKey: (Int, Int, OSType) = (0, 0, 0)
    private var exposure: Float = 0          // smoothed EV for low light
    private var frameCount = 0

    init(options: AppVideoEnhance) { _options = options }

    func process(frame: VideoFrame) -> VideoFrame? {
        let o = options
        guard !o.isNeutral, let input = (frame.buffer as? CVPixelVideoBuffer)?.pixelBuffer else { return frame }
        var image = CIImage(cvPixelBuffer: input)

        if o.lowLight {
            // Measure the mean every 10th frame on a tiny average; aim EV at mid-grey.
            if frameCount % 10 == 0, let mean = meanLuma(image) {
                let target = mean < 0.43 ? min(1.6, max(0, Float(log2(0.43 / max(mean, 0.02))))) : 0
                exposure += (target - exposure) * 0.4
            }
            frameCount &+= 1
            if exposure > 0.02 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure]) }
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.6, "inputHighlightAmount": 1.0])
        } else {
            exposure = 0
        }

        if o.beauty > 0 {
            // Noise reduction smooths flat (skin) areas and keeps edges; blend it
            // in by strength, plus a slight lift.
            let smooth = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.02 + 0.06 * o.beauty, "inputSharpness": 0.2,
            ])
            let mask = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(0.85 * o.beauty))).cropped(to: image.extent)
            image = smooth.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.03 * o.beauty])
            // CIBlendWithAlphaMask uses the mask's alpha as the foreground weight.
        }

        if o.sharpen > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.8 * o.sharpen, kCIInputRadiusKey: 1.5])
        }

        if o.warmth != 0 {
            // Neutral 6500 K; lower target temperature renders warmer.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(6500 - 1500 * o.warmth), y: 0),
            ])
        }

        image = image.cropped(to: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(input), height: CVPixelBufferGetHeight(input)))
        guard let output = makeBuffer(like: input) else { return frame }
        context.render(image, to: output)
        return VideoFrame(dimensions: frame.dimensions, rotation: frame.rotation, timeStampNs: frame.timeStampNs, buffer: CVPixelVideoBuffer(pixelBuffer: output))
    }

    private func meanLuma(_ image: CIImage) -> Float? {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (0.299 * Float(px[0]) + 0.587 * Float(px[1]) + 0.114 * Float(px[2])) / 255
    }

    /// Output buffers come from a pool matching the camera's size and format.
    private func makeBuffer(like input: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(input), h = CVPixelBufferGetHeight(input)
        let fmt = CVPixelBufferGetPixelFormatType(input)
        if pool == nil || poolKey != (w, h, fmt) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: fmt,
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary, attrs as CFDictionary, &p)
            pool = p
            poolKey = (w, h, fmt)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        return out
    }
}

public extension AppEngine {
    /// Built-in camera enhancement: skin smoothing, low-light boost,
    /// sharpening and warmth. Pass nil (or neutral options) to turn it off.
    /// Survives camera off/on, switches and republishes.
    func setVideoEnhance(_ options: AppVideoEnhance?) {
        if let options, !options.isNeutral {
            if let f = videoEnhanceFilter { f.options = options } else { videoEnhanceFilter = AppVideoEnhanceFilter(options: options) }
        } else {
            videoEnhanceFilter = nil
        }
        attachVideoEnhance()
    }

    /// The enhancement in force, or nil when off.
    var videoEnhance: AppVideoEnhance? { videoEnhanceFilter?.options }
}

extension AppEngine {
    /// Puts the current filter (or none) on the camera capturer. The capturer
    /// holds its processor weakly; the engine keeps the strong reference.
    func attachVideoEnhance() {
        guard let capturer = (localVideoTrack as? LocalVideoTrack)?.capturer else { return }
        if capturer.processor !== videoEnhanceFilter { capturer.processor = videoEnhanceFilter }
    }
}
