#if os(iOS) && canImport(HaishinKit)
import Foundation
import AVFoundation
import HaishinKit
import RTMPHaishinKit
import SRTHaishinKit
import CVCore
import CVCapture

/// RTMP/SRT publishing via HaishinKit 2.2.x's `Session` API. The capture
/// engine owns the `AVCaptureSession`; this engine only receives buffers
/// through the `StreamTap` conformance (`StreamConvertible.append`) and never
/// attaches devices itself.
///
/// This file is the single place that touches HaishinKit — if a future
/// release shifts names again, the damage stays here.
public final class HaishinStreamEngine: StreamEngine, StreamTap, @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any Session)?
    private var stream: (any StreamConvertible)?
    private var readyStateTask: Task<Void, Never>?
    private var healthContinuations: [UUID: AsyncStream<StreamHealth>.Continuation] = [:]

    /// RTMP/SRT session factories register once per process.
    private static let factoryRegistration: Task<Void, Never> = Task {
        await SessionBuilderFactory.shared.register(RTMPSessionFactory())
        await SessionBuilderFactory.shared.register(SRTSessionFactory())
    }

    public init() {}

    // MARK: - StreamEngine

    public func connect(to destination: StreamDestination, streamKey: String, quality: VideoQuality) async throws {
        await disconnect()
        emit(.connecting)
        await Self.factoryRegistration.value

        guard let url = Self.publishURL(for: destination, streamKey: streamKey) else {
            emit(.disconnected(reason: "invalid stream URL"))
            throw SessionError.streamConnectFailed("invalid stream URL")
        }

        do {
            guard let session = try await SessionBuilderFactory.shared.make(url)
                .setMode(.publish)
                .build() else {
                throw SessionError.streamConnectFailed("unsupported stream protocol")
            }
            let stream = await session.stream

            var video = await stream.videoSettings
            video.videoSize = CGSize(width: quality.width, height: quality.height)
            video.bitRate = Self.streamBitrate(for: quality)
            try await stream.setVideoSettings(video)

            try await session.connect { [weak self] in
                self?.emit(.disconnected(reason: "connection lost"))
            }

            lock.withLock {
                self.session = session
                self.stream = stream
            }
            watchReadyState(of: session, bitrate: Self.streamBitrate(for: quality))
            emit(.live(bitrateBps: Self.streamBitrate(for: quality), rttMs: nil))
        } catch let error as SessionError {
            emit(.disconnected(reason: error.userMessage))
            throw error
        } catch {
            emit(.disconnected(reason: error.localizedDescription))
            throw SessionError.streamConnectFailed(error.localizedDescription)
        }
    }

    public func disconnect() async {
        let session = lock.withLock { () -> (any Session)? in
            let s = self.session
            self.session = nil
            self.stream = nil
            return s
        }
        readyStateTask?.cancel()
        readyStateTask = nil
        guard let session else { return }
        try? await session.close()
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
        guard let stream = lock.withLock({ stream }) else { return }
        Task { await stream.append(sampleBuffer) }
    }

    public func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        // StreamConvertible.append routes by the buffer's media type.
        guard let stream = lock.withLock({ stream }) else { return }
        Task { await stream.append(sampleBuffer) }
    }

    // MARK: - Internals

    private func watchReadyState(of session: any Session, bitrate: Int) {
        readyStateTask = Task { [weak self] in
            for await state in await session.readyState {
                guard !Task.isCancelled else { return }
                switch state {
                case .connecting:
                    self?.emit(.connecting)
                case .open:
                    self?.emit(.live(bitrateBps: bitrate, rttMs: nil))
                case .closing:
                    break
                case .closed:
                    self?.emit(.disconnected(reason: nil))
                }
            }
        }
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

    /// Builds the full publish URI HaishinKit's session factories expect:
    /// - RTMP: `rtmp://host/app` + `/<streamKey>` as the stream name
    /// - SRT: base URL + `streamid` query (carries MediaMTX publish auth)
    static func publishURL(for destination: StreamDestination, streamKey: String) -> URL? {
        switch destination.kind {
        case .rtmp:
            let base = destination.url.hasSuffix("/") ? String(destination.url.dropLast()) : destination.url
            let full = streamKey.isEmpty ? base : "\(base)/\(streamKey)"
            return URL(string: full)
        case .srt:
            guard var components = URLComponents(string: destination.url) else { return nil }
            if !streamKey.isEmpty {
                var items = components.queryItems ?? []
                items.removeAll { $0.name == "streamid" }
                items.append(URLQueryItem(name: "streamid", value: streamKey))
                components.queryItems = items
            }
            return components.url
        }
    }

    private func emit(_ health: StreamHealth) {
        let conts = lock.withLock { Array(healthContinuations.values) }
        conts.forEach { $0.yield(health) }
    }
}
#endif
