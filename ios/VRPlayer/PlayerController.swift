import UIKit
import AVFoundation

@MainActor
final class PlayerController: UIViewController, UIGestureRecognizerDelegate {
    let engine = PlaybackEngine()
    private let movie: MovieSource
    private let topBar = UIStackView()
    private let bottomBar = UIStackView()
    private let playButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)
    private let slider = UISlider()
    private let timeLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private var hideTask: Task<Void, Never>?
    private var controlsVisible = true
    private var seeking = false
    private var pinchStart: Float = 80
    private var streamAttempt = 0
    private var failureTask: Task<Void, Never>?
    private var lastPlaying = false

    init(movie: MovieSource) { self.movie = movie; super.init(nibName: nil, bundle: nil); modalPresentationStyle = .fullScreen }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { !controlsVisible }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let metal = engine.renderer.metalView
        view.addSubview(metal)
        metal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([metal.leadingAnchor.constraint(equalTo: view.leadingAnchor), metal.trailingAnchor.constraint(equalTo: view.trailingAnchor), metal.topAnchor.constraint(equalTo: view.topAnchor), metal.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        for gesture in [tap, pan, pinch] { gesture.delegate = self; metal.addGestureRecognizer(gesture) }
        tap.require(toFail: pan); tap.require(toFail: pinch)

        topBar.axis = .horizontal; topBar.spacing = 12; topBar.alignment = .center
        let back = button("chevron.down", label: "Close movie", action: #selector(closeMovie))
        let title = UILabel(); title.text = movie.title; title.font = .preferredFont(forTextStyle: .headline); title.textColor = .white
        title.lineBreakMode = .byTruncatingMiddle
        settingsButton.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        settingsButton.accessibilityLabel = "Viewing settings"
        settingsButton.showsMenuAsPrimaryAction = true
        settingsButton.tintColor = .white
        settingsButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        settingsButton.heightAnchor.constraint(equalToConstant: 48).isActive = true
        topBar.addArrangedSubview(back); topBar.addArrangedSubview(title); topBar.addArrangedSubview(settingsButton)

        bottomBar.axis = .vertical; bottomBar.spacing = 8
        let row = UIStackView(); row.axis = .horizontal; row.spacing = 16; row.alignment = .center
        playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playButton.tintColor = .white; playButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)
        playButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        playButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let rewind = button("gobackward.10", label: "Back ten seconds", action: #selector(rewind))
        let forward = button("goforward.10", label: "Forward ten seconds", action: #selector(forward))
        timeLabel.textColor = .white; timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        timeLabel.textAlignment = .right
        row.addArrangedSubview(playButton); row.addArrangedSubview(rewind); row.addArrangedSubview(forward); row.addArrangedSubview(timeLabel)
        slider.minimumValue = 0; slider.maximumValue = 1; slider.tintColor = .systemCyan; slider.accessibilityLabel = "Playback position"
        slider.addTarget(self, action: #selector(beginSeek), for: .touchDown)
        slider.addTarget(self, action: #selector(seekChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(endSeek), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        bottomBar.addArrangedSubview(row); bottomBar.addArrangedSubview(slider)
        for bar in [topBar, bottomBar] {
            bar.isLayoutMarginsRelativeArrangement = true
            bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            bar.backgroundColor = UIColor.black.withAlphaComponent(0.72)
            bar.layer.cornerRadius = 16
            view.addSubview(bar); bar.translatesAutoresizingMaskIntoConstraints = false
        }
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8), topBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12), topBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
            bottomBar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -8), bottomBar.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12), bottomBar.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12)])
        spinner.color = .white; view.addSubview(spinner); spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        engine.onChange = { [weak self] in self?.refresh() }
        engine.onFailure = { [weak self] message in self?.handleFailure(message) }
        engine.open(movie)
        refreshSettings()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed { hideTask?.cancel(); failureTask?.cancel(); engine.close() }
    }
    private func button(_ image: String, label: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: image), for: .normal); button.accessibilityLabel = label; button.tintColor = .white
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true; button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
    private func refresh() {
        playButton.setImage(UIImage(systemName: engine.playing ? "pause.fill" : "play.fill"), for: .normal)
        playButton.accessibilityLabel = engine.playing ? "Pause" : "Play"
        if !seeking {
            slider.value = engine.duration > 0 ? Float(engine.position / engine.duration) : 0
            timeLabel.text = "\(time(engine.position)) / \(time(engine.duration))"
        }
        slider.isEnabled = engine.duration > 0
        if engine.loading || engine.player.timeControlStatus == .waitingToPlayAtSpecifiedRate { spinner.startAnimating() } else { spinner.stopAnimating() }
        if engine.playing != lastPlaying {
            lastPlaying = engine.playing
            if engine.playing { scheduleHide() } else { setControls(true) }
        }
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite ? max(0, seconds) : 0)
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
    private func setControls(_ visible: Bool) {
        controlsVisible = visible
        topBar.isHidden = !visible; bottomBar.isHidden = !visible
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        hideTask?.cancel()
        if visible && engine.playing { scheduleHide() }
    }
    private func scheduleHide() {
        hideTask?.cancel()
        guard !UIAccessibility.isVoiceOverRunning else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.engine.playing, !self.seeking, self.presentedViewController == nil else { return }
            self.setControls(false)
        }
    }
    @objc private func tapped() { setControls(!controlsVisible) }
    @objc private func togglePlay() { engine.perform(.togglePlay); scheduleHide() }
    @objc private func rewind() { engine.perform(.seek(engine.position - 10)); scheduleHide() }
    @objc private func forward() { engine.perform(.seek(engine.position + 10)); scheduleHide() }
    @objc private func beginSeek() { seeking = true; hideTask?.cancel() }
    @objc private func seekChanged() { timeLabel.text = "\(time(Double(slider.value) * engine.duration)) / \(time(engine.duration))" }
    @objc private func endSeek() { seeking = false; engine.perform(.seek(Double(slider.value) * engine.duration)); scheduleHide() }
    @objc private func closeMovie() { hideTask?.cancel(); failureTask?.cancel(); engine.close(); dismiss(animated: true) }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: view)
        let scale = engine.renderer.viewState.fieldOfView * .pi / 180 / Float(max(1, view.bounds.height))
        var state = engine.renderer.viewState
        state.yaw -= Float(delta.x) * scale
        state.pitch += Float(delta.y) * scale
        state.constrain(aspect: Float(view.bounds.width / max(1, view.bounds.height)))
        engine.renderer.viewState = state
        gesture.setTranslation(.zero, in: view)
        if gesture.state == .began { setControls(false) }
        if gesture.state == .ended { engine.save() }
    }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinchStart = engine.renderer.viewState.fieldOfView; setControls(false) }
        var state = engine.renderer.viewState
        state.fieldOfView = 2 * atan(tan(pinchStart * .pi / 360) / Float(max(0.01, gesture.scale))) * 180 / .pi
        state.constrain(aspect: Float(view.bounds.width / max(1, view.bounds.height)))
        engine.renderer.viewState = state
        if gesture.state == .ended { engine.save() }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }
    private func refreshSettings() {
        let state = engine.renderer.viewState
        settingsButton.menu = UIMenu(children: [
            UIMenu(title: "Eye", options: .displayInline, children: [
                UIAction(title: "Left eye", state: state.rightEye ? .off : .on) { [weak self] _ in self?.setting(.selectEye(false)) },
                UIAction(title: "Right eye", state: state.rightEye ? .on : .off) { [weak self] _ in self?.setting(.selectEye(true)) }]),
            UIMenu(title: "180° projection", options: .displayInline, children: [
                UIAction(title: "Standard", state: state.fisheye ? .off : .on) { [weak self] _ in self?.setting(.selectFisheye(false)) },
                UIAction(title: "Fisheye", state: state.fisheye ? .on : .off) { [weak self] _ in self?.setting(.selectFisheye(true)) }]),
            UIAction(title: "Reset view", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in self?.setting(.resetView) },
            UIAction(title: "Playback details", image: UIImage(systemName: "info.circle")) { [weak self] _ in
                guard let self else { return }
                let alert = UIAlertController(title: "Playback details", message: self.engine.diagnostics, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Done", style: .default) { _ in self.scheduleHide() }); self.present(alert, animated: true)
            }
        ])
    }
    private func setting(_ action: PlaybackAction) { engine.perform(action); engine.save(); refreshSettings(); scheduleHide() }
    private func handleFailure(_ message: String) {
        setControls(true)
        if streamAttempt == 0, let source = engine.source, let plex = source.plex {
            streamAttempt = 1
            failureTask = Task {
                do {
                    let next = try await plex.service.convertedSource(source, allowVideoConversion: false)
                    guard !Task.isCancelled else { return }
                    engine.open(next, resumeAt: engine.position, preserveView: true)
                } catch is CancellationError {} catch { showError(message + "\n\n" + error.localizedDescription, allowConversion: true) }
            }
        } else { showError(message, allowConversion: streamAttempt == 1 && engine.source?.plex != nil) }
    }
    private func showError(_ message: String, allowConversion: Bool) {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Playback needs attention", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Reconnect and retry", style: .default) { [weak self] _ in self?.engine.reconnect() })
        if allowConversion {
            alert.addAction(UIAlertAction(title: "Allow Plex video conversion…", style: .default) { [weak self] _ in self?.confirmConversion() })
        }
        alert.addAction(UIAlertAction(title: "Close movie", style: .cancel) { [weak self] _ in self?.closeMovie() })
        present(alert, animated: true)
    }
    private func confirmConversion() {
        let alert = UIAlertController(title: "Allow lower picture quality?", message: "Plex will convert this video for playback. Conversion can reduce detail, frame rate, or HDR. The player will preserve the stereo layout.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep original", style: .cancel))
        alert.addAction(UIAlertAction(title: "Convert and play", style: .default) { [weak self] _ in
            guard let self, let source = self.engine.source, let plex = source.plex else { return }
            self.streamAttempt = 2
            self.failureTask = Task {
                do {
                    let next = try await plex.service.convertedSource(source, allowVideoConversion: true)
                    guard !Task.isCancelled else { return }
                    self.engine.open(next, resumeAt: self.engine.position, preserveView: true)
                } catch is CancellationError {} catch { self.showError(error.localizedDescription, allowConversion: false) }
            }
        })
        present(alert, animated: true)
    }
}
