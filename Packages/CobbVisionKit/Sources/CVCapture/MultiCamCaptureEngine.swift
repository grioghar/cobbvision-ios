#if os(iOS)
import Foundation
import AVFoundation
import CVCore

/// Real capture engine: `AVCaptureMultiCamSession` for `.both`, plain
/// `AVCaptureSession` for a single camera. All session mutation happens on
/// `sessionQueue`; sample buffers fan out from the delegate (also on
/// `sessionQueue`) to per-camera recorders and the optional stream tap.
public final class MultiCamCaptureEngine: NSObject, CaptureEngine, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(label: "co.grio.cobbvision.capture")

    private var session: AVCaptureSession?
    private var spec: CaptureSpec?
    private var videoOutputs: [CameraPosition: AVCaptureVideoDataOutput] = [:]
    private var audioOutput: AVCaptureAudioDataOutput?
    private var devices: [CameraPosition: AVCaptureDevice] = [:]
    private var previewLayers: [CameraPosition: AVCaptureVideoPreviewLayer] = [:]

    private var recorders: [CameraPosition: CameraRecorder] = [:]
    private var streamTap: StreamTap?
    private var streamCamera: CameraPosition?
    /// Audio routes into this camera's file (rear when both record).
    private var audioCamera: CameraPosition?

    private var eventContinuations: [UUID: AsyncStream<CaptureEvent>.Continuation] = [:]
    private var observers: [NSObjectProtocol] = []
    private var steppedDownFrameRate = false

    public override init() {
        super.init()
    }

    // MARK: - CaptureEngine

    public func configure(_ spec: CaptureSpec) async throws {
        try await onSessionQueue { [self] in
            try configureLocked(spec)
        }
    }

    public func start() async throws {
        try await onSessionQueue { [self] in
            guard let session else { throw SessionError.internalFailure("not configured") }
            try Self.activateAudioSession()
            session.startRunning()
            if !session.isRunning {
                throw SessionError.cameraUnavailable("capture session refused to start")
            }
        }
    }

    public func stop() async {
        try? await onSessionQueue { [self] in
            session?.stopRunning()
            removeObserversLocked()
            session = nil
            videoOutputs = [:]
            audioOutput = nil
            devices = [:]
            previewLayers = [:]
            streamTap = nil
            streamCamera = nil
        }
    }

    public func startRecording(to directory: URL) async throws {
        try await onSessionQueue { [self] in
            guard let spec else { throw SessionError.internalFailure("not configured") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let positions = spec.cameras.positions
            audioCamera = positions.contains(.rear) ? .rear : positions.first
            for position in positions {
                recorders[position] = try CameraRecorder(
                    camera: position,
                    directory: directory,
                    quality: spec.quality,
                    recordAudio: spec.enableAudio && position == audioCamera
                )
            }
        }
    }

    public func stopRecording() async throws -> [RecordedVideo] {
        let finished: [CameraRecorder] = try await onSessionQueue { [self] in
            let active = Array(recorders.values)
            recorders = [:]
            return active
        }
        var results: [RecordedVideo] = []
        for recorder in finished {
            results.append(try await recorder.finish())
        }
        return results
    }

    public func attachStreamTap(_ tap: StreamTap, camera: CameraPosition) async throws {
        try await onSessionQueue { [self] in
            guard videoOutputs[camera] != nil else {
                throw SessionError.cameraUnavailable("\(camera.rawValue) camera not configured for streaming")
            }
            streamTap = tap
            streamCamera = camera
        }
    }

    public func detachStreamTap() async {
        try? await onSessionQueue { [self] in
            streamTap = nil
            streamCamera = nil
        }
    }

    public func events() -> AsyncStream<CaptureEvent> {
        AsyncStream { continuation in
            let id = UUID()
            sessionQueue.async { [self] in
                eventContinuations[id] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.sessionQueue.async {
                    self?.eventContinuations[id] = nil
                }
            }
        }
    }

    /// For SwiftUI previews (UIViewRepresentable hosts the layer). Available
    /// after `configure`.
    public func previewLayer(for position: CameraPosition) -> AVCaptureVideoPreviewLayer? {
        sessionQueue.sync { previewLayers[position] }
    }

    public static var isMultiCamSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    // MARK: - Configuration (on sessionQueue)

    private func configureLocked(_ spec: CaptureSpec) throws {
        guard case .authorized = AVCaptureDevice.authorizationStatus(for: .video) else {
            throw SessionError.permissionDenied("camera access")
        }

        let multiCam = spec.cameras == .both
        if multiCam, !AVCaptureMultiCamSession.isMultiCamSupported {
            throw SessionError.multiCamUnsupported
        }

        let session = multiCam ? AVCaptureMultiCamSession() : AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        self.spec = spec
        self.session = session

        for position in spec.cameras.positions {
            try addCamera(position, to: session, spec: spec, multiCam: multiCam)
        }

        if spec.enableAudio {
            try addAudio(to: session, multiCam: multiCam)
        }

        installObserversLocked(session: session)
        steppedDownFrameRate = false
    }

    private func addCamera(
        _ position: CameraPosition,
        to session: AVCaptureSession,
        spec: CaptureSpec,
        multiCam: Bool
    ) throws {
        let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: avPosition) else {
            throw SessionError.cameraUnavailable("no \(position.rawValue) camera")
        }
        devices[position] = device

        // Pick + apply a format the hardware can actually run (multi-cam
        // formats are a restricted subset).
        let descriptors = device.formats.enumerated().map { index, format -> FormatDescriptor in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let maxRate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return FormatDescriptor(
                width: Int(dims.width),
                height: Int(dims.height),
                maxFrameRate: maxRate,
                isMultiCamSupported: format.isMultiCamSupported,
                index: index
            )
        }
        guard let choice = FormatPicker.pick(
            formats: descriptors,
            quality: spec.quality,
            requireMultiCam: multiCam
        ) else {
            throw SessionError.cameraUnavailable("no usable \(position.rawValue) camera format")
        }
        try device.lockForConfiguration()
        device.activeFormat = device.formats[choice.format.index]
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(choice.frameRate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sessionQueue)

        if multiCam {
            guard session.canAddInput(input) else {
                throw SessionError.cameraUnavailable("can't add \(position.rawValue) input")
            }
            session.addInputWithNoConnections(input)
            guard session.canAddOutput(output) else {
                throw SessionError.cameraUnavailable("can't add \(position.rawValue) output")
            }
            session.addOutputWithNoConnections(output)

            guard let videoPort = input.ports(for: .video, sourceDeviceType: device.deviceType, sourceDevicePosition: device.position).first else {
                throw SessionError.cameraUnavailable("no video port on \(position.rawValue) camera")
            }
            let connection = AVCaptureConnection(inputPorts: [videoPort], output: output)
            guard session.canAddConnection(connection) else {
                throw SessionError.cameraUnavailable("can't connect \(position.rawValue) camera")
            }
            session.addConnection(connection)

            let preview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: session)
            let previewConnection = AVCaptureConnection(inputPort: videoPort, videoPreviewLayer: preview)
            if session.canAddConnection(previewConnection) {
                session.addConnection(previewConnection)
            }
            previewLayers[position] = preview
        } else {
            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw SessionError.cameraUnavailable("can't add \(position.rawValue) camera")
            }
            session.addInput(input)
            session.addOutput(output)
            previewLayers[position] = AVCaptureVideoPreviewLayer(session: session)
        }

        videoOutputs[position] = output
    }

    private func addAudio(to session: AVCaptureSession, multiCam: Bool) throws {
        guard let mic = AVCaptureDevice.default(for: .audio) else { return }
        let input = try AVCaptureDeviceInput(device: mic)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: sessionQueue)
        if multiCam {
            guard session.canAddInput(input), session.canAddOutput(output) else { return }
            session.addInputWithNoConnections(input)
            session.addOutputWithNoConnections(output)
            guard let port = input.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .unspecified).first else { return }
            let connection = AVCaptureConnection(inputPorts: [port], output: output)
            if session.canAddConnection(connection) {
                session.addConnection(connection)
            }
        } else {
            guard session.canAddInput(input), session.canAddOutput(output) else { return }
            session.addInput(input)
            session.addOutput(output)
        }
        audioOutput = output
    }

    private static func activateAudioSession() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers])
        try audio.setActive(true)
    }

    // MARK: - Thermal + interruption observers (on sessionQueue)

    private func installObserversLocked(session: AVCaptureSession) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.sessionQueue.async { self?.handleThermalLocked() }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).map(String.init) ?? "unknown"
            self?.sessionQueue.async { self?.emitLocked(.interrupted(reason: reason)) }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.sessionQueue.async { self?.emitLocked(.interruptionEnded) }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? AVError)?.localizedDescription ?? "unknown"
            self?.sessionQueue.async { self?.emitLocked(.runtimeError(message)) }
        })
    }

    private func removeObserversLocked() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations = [:]
    }

    /// At `.serious` thermal pressure, clamp to 30 fps before iOS interrupts
    /// the whole session. Resolution swaps need a full reconfigure — frame
    /// rate is the cheap lever.
    private func handleThermalLocked() {
        let state = ProcessInfo.processInfo.thermalState
        guard state == .serious || state == .critical, !steppedDownFrameRate else { return }
        var stepped = false
        for device in devices.values {
            let current = device.activeVideoMinFrameDuration
            guard current.isValid, current.seconds > 0, 1.0 / current.seconds > 30 else { continue }
            if (try? device.lockForConfiguration()) != nil {
                let thirty = CMTime(value: 1, timescale: 30)
                device.activeVideoMinFrameDuration = thirty
                device.activeVideoMaxFrameDuration = thirty
                device.unlockForConfiguration()
                stepped = true
            }
        }
        if stepped {
            steppedDownFrameRate = true
            emitLocked(.thermalStepDown(to: 30))
        }
    }

    private func emitLocked(_ event: CaptureEvent) {
        eventContinuations.values.forEach { $0.yield(event) }
    }

    // MARK: - Queue bridging

    private func onSessionQueue<T: Sendable>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Sample buffer routing (called on sessionQueue)

extension MultiCamCaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            if let audioCamera { recorders[audioCamera]?.appendAudio(sampleBuffer) }
            streamTap?.appendAudio(sampleBuffer)
            return
        }
        guard let position = videoOutputs.first(where: { $0.value === output })?.key else { return }
        recorders[position]?.appendVideo(sampleBuffer)
        if position == streamCamera {
            streamTap?.appendVideo(sampleBuffer)
        }
    }
}
#endif
