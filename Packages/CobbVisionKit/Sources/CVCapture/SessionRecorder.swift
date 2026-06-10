#if os(iOS)
import Foundation
import AVFoundation
import CVCore

/// One `AVAssetWriter` per camera. Buffers arrive on the capture queue;
/// the writer session starts at the first video PTS so audio/video stay
/// aligned. HEVC when the hardware has it (every multi-cam-capable phone
/// does), H.264 otherwise.
final class CameraRecorder {
    let camera: CameraPosition
    let fileURL: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?

    init(camera: CameraPosition, directory: URL, quality: VideoQuality, recordAudio: Bool) throws {
        self.camera = camera
        self.fileURL = directory.appendingPathComponent("\(camera.rawValue).mov")
        try? FileManager.default.removeItem(at: fileURL)

        writer = try AVAssetWriter(outputURL: fileURL, fileType: .mov)

        let codec: AVVideoCodecType = AVAssetWriter.hevcSupported ? .hevc : .h264
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: quality.width,
            AVVideoHeightKey: quality.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.recordBitrate,
                AVVideoExpectedSourceFrameRateKey: quality.frameRate,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        if recordAudio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ])
            audio.expectsMediaDataInRealTime = true
            writer.add(audio)
            audioInput = audio
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw SessionError.internalFailure("recorder start failed: \(writer.error?.localizedDescription ?? "?")")
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            firstPTS = pts
        }
        lastPTS = pts
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        // Audio before the first video frame would force a session start at
        // audio PTS and leave black frames; drop until video anchors.
        guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    func finish() async throws -> RecordedVideo {
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        guard sessionStarted else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: fileURL)
            throw SessionError.internalFailure("no frames captured for \(camera.rawValue) camera")
        }
        await writer.finishWriting()
        if writer.status == .failed {
            throw SessionError.internalFailure("finalize failed: \(writer.error?.localizedDescription ?? "?")")
        }
        let duration: Double? = {
            guard let firstPTS, let lastPTS else { return nil }
            return CMTimeGetSeconds(CMTimeSubtract(lastPTS, firstPTS))
        }()
        return RecordedVideo(
            fileName: fileURL.lastPathComponent,
            camera: camera,
            durationSeconds: duration
        )
    }
}

extension AVAssetWriter {
    static var hevcSupported: Bool {
        AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
    }
}
#endif
