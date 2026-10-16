import AVFoundation
import UIKit
import os

enum PlaybackAction {
    case togglePlay, seek(Double), resetView, selectEye(Bool), selectFisheye(Bool)
}

struct MovieSource {
    var id: String
    var title: String
    var url: URL
    var headers: [String: String] = [:]
    var plex: PlexPlaybackContext?
}

@MainActor
final class PlaybackEngine {
    let player = AVPlayer()
    let renderer = VideoRenderer()
    var source: MovieSource?
    var onChange: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var error: String?
    private(set) var loading = false
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var diagnostics = ""
    private let history = PlaybackHistory()
    private var statusObservation: NSKeyValueObservation?
    private var timeObservation: NSKeyValueObservation?
    private var periodic: Any?
    private var notifications: [NSObjectProtocol] = []
    private var openTask: Task<Void, Never>?
    private var lastSave: Double = 0
    private var sourceDetails = ""
    private var metricsStartedAt = CACurrentMediaTime()
    private var sourceFrameRate: Float = 0
    private let log = Logger(subsystem: "com.mikepearlman.vrplayer", category: "Playback")
    var playing: Bool { player.rate > 0 }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.allowsExternalPlayback = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.loading else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if abs(self.position - self.lastSave) >= 5 { self.save(); self.lastSave = self.position }
                self.onChange?()
            }
        }
        timeObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }
        renderer.onMetrics = { [weak self] decoded, drawn, thermal in
            guard let self else { return }
            let elapsed = max(0.001, CACurrentMediaTime() - self.metricsStartedAt)
            self.diagnostics = self.sourceDetails + "\nFrames: \(decoded) decoded · \(drawn) drawn · Heat: \(thermal.rawValue)"
            let metrics: [String: Any] = ["decodedFrames": decoded, "renderedFrames": drawn, "elapsedSeconds": elapsed,
                "sourceFPS": self.sourceFrameRate, "position": self.position, "thermalState": thermal.rawValue,
                "playing": self.playing, "failed": self.error != nil, "format": self.sourceDetails]
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: .prettyPrinted) {
                try? data.write(to: URL.cachesDirectory.appending(path: "PlaybackDiagnostics.json"), options: .atomic)
            }
            self.log.info("\(self.diagnostics, privacy: .public)")
        }
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.save(); self?.player.pause(); self?.renderer.stop() }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.source != nil { self?.renderer.start() } }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.player.pause(); self?.onChange?() }
        })
    }
    func open(_ movie: MovieSource, resumeAt: Double? = nil, preserveView: Bool = false) {
        save()
        openTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        renderer.reset()
        metricsStartedAt = CACurrentMediaTime()
        source = movie
        error = nil
        loading = true
        duration = 0
        position = 0
        lastSave = 0
        if !preserveView { renderer.viewState = history.load(movie.id)?.view ?? ViewState() }
        let savedPosition = resumeAt ?? history.load(movie.id)?.seconds ?? 0
        onChange?()
        openTask = Task {
            do {
                let asset = AVURLAsset(url: movie.url, options: movie.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": movie.headers])
                guard try await asset.load(.isPlayable) else { throw PlayerError.message("This movie cannot play in Apple’s video decoder.") }
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw PlayerError.message("This file has no video track.") }
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let frameRate = try await track.load(.nominalFrameRate)
                let length = try await asset.load(.duration)
                try Task.checkCancellation()
                self.renderer.sourceSize = size
                self.renderer.sourceTransform = transform
                self.duration = length.seconds.isFinite ? length.seconds : 0
                self.sourceFrameRate = frameRate
                self.sourceDetails = "\(Int(size.width))×\(Int(size.height)) · \(String(format: "%.2f", frameRate)) fps"
                self.diagnostics = self.sourceDetails
                self.log.info("Opening \(self.diagnostics, privacy: .public)")
                let item = AVPlayerItem(asset: asset)
                let output = AVPlayerItemVideoOutput(outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64RGBAHalf,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                    AVVideoAllowWideColorKey: true,
                    AVVideoColorPropertiesKey: [
                        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
                    ]
                ])
                item.add(output)
                self.renderer.output = output
                self.statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.player.currentItem === item else { return }
                        if item.status == .failed {
                            self.fail(item.error?.localizedDescription ?? "The movie stopped playing.")
                        } else if item.status == .readyToPlay {
                            self.loading = false
                            self.onChange?()
                        }
                    }
                }
                self.player.replaceCurrentItem(with: item)
                self.renderer.start()
                let start = min(savedPosition, max(0, self.duration - 1))
                if start > 0 { await self.player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
                try Task.checkCancellation()
                self.player.play()
                UIApplication.shared.isIdleTimerDisabled = true
            } catch is CancellationError {
            } catch { if !Task.isCancelled { self.fail(error.localizedDescription) } }
        }
    }
    func perform(_ action: PlaybackAction) {
        switch action {
        case .togglePlay:
            if playing { player.pause() } else { player.play() }
        case .seek(let seconds):
            player.seek(to: CMTime(seconds: min(max(0, seconds), duration), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        case .resetView:
            var state = renderer.viewState
            state.yaw = 0; state.pitch = 0; state.fieldOfView = 80
            renderer.viewState = state
        case .selectEye(let right): renderer.viewState.rightEye = right
        case .selectFisheye(let fisheye): renderer.viewState.fisheye = fisheye
        }
        onChange?()
    }
    func reconnect() {
        guard let source else { return }
        open(source, resumeAt: position, preserveView: true)
    }
    func save() {
        guard let source, !loading, error == nil else { return }
        history.save(source.id, seconds: position, view: renderer.viewState)
    }
    func close() {
        save()
        openTask?.cancel()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        renderer.stop()
        renderer.reset()
        if let plex = source?.plex { Task { await plex.stopSession() } }
        source = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }
    private func fail(_ message: String) {
        loading = false
        error = message
        player.pause()
        log.error("Playback failed: \(message, privacy: .private)")
        onChange?()
        onFailure?(message)
    }
    deinit {
        if let periodic { player.removeTimeObserver(periodic) }
        notifications.forEach(NotificationCenter.default.removeObserver)
    }
}

enum PlayerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}
