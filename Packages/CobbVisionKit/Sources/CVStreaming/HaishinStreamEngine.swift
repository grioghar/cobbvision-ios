#if os(iOS) && canImport(HaishinKit)
import Foundation
import AVFoundation
import HaishinKit
import SRTHaishinKit
import CVCore
import CVCapture

/// RTMP/SRT publishing via HaishinKit 2.x. The capture engine owns the
/// `AVCaptureSession`; this engine only receives buffers through the
/// `StreamTap` conformance and never attaches devices itself.
///
/// NOTE: HaishinKit 2.x reorganized its API around actors (`RTMPConnection`,
/// `RTMPStream`, `SRTConnection`, `SRTStream`). This file is the single place
/// that touches it — if the pinned release shifts names, the damage stays here.
public final class HaishinStreamEngine: StreamEngine, StreamTap, @unchecked Sendable {
    private enum Transport {
        case rtmp(connection: RTMPConnection, stream: RTMPStream)
        case srt(connection: SRTConnection, stream: SRTStream)
    }

    private let lock = NSLock()
    private var transport: Transport?
    private var healthContinuations: [UUID: AsyncStream<StreamHealth>.Continuation] = [:]

    public init() {}

    // MARK: - StreamEngine

    public func connect(to destination: StreamDestination, streamKey: String, quality: VideoQuality) async throws {
        await disconnect()
        emit(.connecting)

        do {
            switch destination.kind {
            case .rtmp:
                let connection = RTMPConnection()
                let stream = RTMPStream(connection: connection)
                try await configureVideo(stream: stream, quality: quality)
                _ = try await connection.connect(destination.url)
                _ = try await stream.publish(streamKey)
                setTransport(.rtmp(connection: connection, stream: stream))

            case .srt:
                guard let url = Self.srtURL(base: destination.url, streamID: streamKey) else {
                    throw SessionError.streamConnectFailed("invalid SRT URL")
                }
                let connection = SRTConnection()
                let stream = SRTStream(connection: connection)
                try await configureVideo(stream: stream, quality: quality)
                try await connection.connect(url)
                await stream.publish()
                setTransport(.srt(connection: connection, stream: stream))
            }
            emit(.live(bitrateBps: Self.streamBitrate(for: quality), rttMs: nil))
        } catch {
            emit(.disconnected(reason: error.localizedDescription))
            throw SessionError.streamConnectFailed(error.localizedDescription)
        }
    }

    public func disconnect() async {
        let current = lock.withLock { () -> Transport? in
            let t = transport
            transport = nil
            return t
        }
        guard let current else { return }
        switch current {
        case .rtmp(let connection, let stream):
            try? await stream.close()
            try? await connection.close()
        case .srt(let connection, let stream):
            await stream.close()
            try? await connection.close()
        }
        emit(.disconnected(reason: nil))
    }

    public func health() -> AsyncStream<StreamHealth> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { healthContinuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                _ = self?.lock.withLock { self?.healthContinuations.removeValue(forKey: id) }
            }
        }
    }

    // MARK: - StreamTap (called on the capture queue — hand off fast)

    public func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let transport = lock.withLock({ transport }) else { return }
        switch transport {
        case .rtmp(_, let stream):
            Task { await stream.append(sampleBuffer) }
        case .srt(_, let stream):
            Task { await stream.append(sampleBuffer) }
        }
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let transport = lock.withLock({ transport }) else { return }
        switch transport {
        case .rtmp(_, let stream):
            Task { await stream.append(sampleBuffer) }
        case .srt(_, let stream):
            Task { await stream.append(sampleBuffer) }
        }
    }

    // MARK: - Internals

    private func configureVideo(stream: some HKStream, quality: VideoQuality) async throws {
        var video = await stream.videoSettings
        video.videoSize = CGSize(width: quality.width, height: quality.height)
        video.bitRate = Self.streamBitrate(for: quality)
        await stream.setVideoSettings(video)
    }

    /// Streaming bitrates are lower than recording bitrates — cellular uplink
    /// is the constraint, not quality.
    static func streamBitrate(for quality: VideoQuality) -> Int {
        switch quality {
        case .hd720_30: 2_500_000
        case .hd1080_30: 4_500_000
        case .hd1080_60: 6_000_000
        case .uhd4k_30: 8_000_000
        }
    }

    /// Joins the configured SRT base URL with the streamid (which carries
    /// MediaMTX publish auth, e.g. `publish:cobbvision:cobb:password`).
    static func srtURL(base: String, streamID: String) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        if !streamID.isEmpty {
            var items = components.queryItems ?? []
            items.removeAll { $0.name == "streamid" }
            items.append(URLQueryItem(name: "streamid", value: streamID))
            components.queryItems = items
        }
        return components.url
    }

    private func setTransport(_ t: Transport) {
        lock.withLock { transport = t }
    }

    private func emit(_ health: StreamHealth) {
        let conts = lock.withLock { Array(healthContinuations.values) }
        conts.forEach { $0.yield(health) }
    }
}
#endif
