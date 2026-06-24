@preconcurrency import AVFoundation
import Foundation
import Vision

enum MediaPresenceDetectionResult: String, Sendable {
    case human
    case noHuman = "no_human"
    case unavailable
}

protocol MediaPresenceDetecting: AnyObject, Sendable {
    func detectPresence() async -> MediaPresenceDetectionResult
}

final class MediaPresenceProbe: NSObject, MediaPresenceDetecting, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var continuation: CheckedContinuation<MediaPresenceDetectionResult, Never>?
    private var timeoutTimer: DispatchSourceTimer?

    func detectPresence() async -> MediaPresenceDetectionResult {
        guard await cameraAccessGranted() else {
            return .unavailable
        }
        return await capturePresence()
    }

    private func capturePresence(timeoutNanoseconds: UInt64 = 3_000_000_000) async -> MediaPresenceDetectionResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            DispatchQueue.global(qos: .userInitiated).async {
                self.start(timeoutNanoseconds: timeoutNanoseconds)
            }
        }
    }

    private func start(timeoutNanoseconds: UInt64) {
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            finish(result: .unavailable)
            return
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(
            self,
            queue: DispatchQueue(label: "com.fpieringer.Keyway.media-presence-probe.video")
        )
        guard session.canAddOutput(output) else {
            finish(result: .unavailable)
            return
        }
        session.addOutput(output)

        lock.lock()
        self.session = session
        lock.unlock()

        armTimeout(timeoutNanoseconds: timeoutNanoseconds)
        session.startRunning()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        finish(result: classify(sampleBuffer: sampleBuffer))
    }

    private func classify(sampleBuffer: CMSampleBuffer) -> MediaPresenceDetectionResult {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .unavailable
        }
        return (request.results?.isEmpty ?? true) ? .noHuman : .human
    }

    private func armTimeout(timeoutNanoseconds: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds)))
        timer.setEventHandler { [weak self] in
            self?.finish(result: .unavailable)
        }

        lock.lock()
        timeoutTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func finish(result: MediaPresenceDetectionResult) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }

        self.continuation = nil
        let session = self.session
        self.session = nil
        let timeoutTimer = self.timeoutTimer
        self.timeoutTimer = nil
        lock.unlock()

        timeoutTimer?.cancel()
        if session?.isRunning == true {
            DispatchQueue.global(qos: .utility).async {
                session?.stopRunning()
            }
        }
        continuation.resume(returning: result)
    }

    private func cameraAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
