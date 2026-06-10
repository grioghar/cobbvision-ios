import Foundation
import CVCore

/// Platform-pure view of an `AVCaptureDevice.Format`, so the selection ladder
/// is unit-testable on any host (the simulator has no cameras and CI has no
/// devices — this logic is where multi-cam bugs would otherwise hide).
public struct FormatDescriptor: Sendable, Hashable {
    public var width: Int
    public var height: Int
    public var maxFrameRate: Double
    public var isMultiCamSupported: Bool
    /// Lower is cheaper; mirrors AVFoundation's hardware cost ordering by
    /// index when real costs aren't available.
    public var index: Int

    public init(width: Int, height: Int, maxFrameRate: Double, isMultiCamSupported: Bool, index: Int) {
        self.width = width
        self.height = height
        self.maxFrameRate = maxFrameRate
        self.isMultiCamSupported = isMultiCamSupported
        self.index = index
    }
}

public enum FormatPicker {
    public struct Choice: Sendable, Hashable {
        public var format: FormatDescriptor
        public var frameRate: Int
        /// The quality the choice actually delivers (after any step-down).
        public var effectiveQuality: VideoQuality
    }

    /// Picks the cheapest format satisfying `quality`, walking the quality
    /// ladder down until something fits. Multi-cam sessions only consider
    /// `isMultiCamSupported` formats — dual 4K is rejected by hardware, so
    /// honest degradation beats a configure-time crash.
    public static func pick(
        formats: [FormatDescriptor],
        quality: VideoQuality,
        requireMultiCam: Bool
    ) -> Choice? {
        let eligible = formats.filter { !requireMultiCam || $0.isMultiCamSupported }
        var rung: VideoQuality? = quality
        while let q = rung {
            let fits = eligible.filter {
                $0.width >= q.width && $0.height >= q.height && $0.maxFrameRate >= Double(q.frameRate)
            }
            if let best = fits.min(by: { lhs, rhs in
                // Smallest format that satisfies the rung, then lowest index.
                (lhs.width * lhs.height, lhs.maxFrameRate, lhs.index)
                    < (rhs.width * rhs.height, rhs.maxFrameRate, rhs.index)
            }) {
                return Choice(format: best, frameRate: q.frameRate, effectiveQuality: q)
            }
            rung = q.steppedDown
        }
        return nil
    }
}
