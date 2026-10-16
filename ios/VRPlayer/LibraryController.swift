import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct RecentMovie: Codable {
    let id: String
    let title: String
    let bookmark: Data?
    let managedName: String?
}

@MainActor
final class LibraryController: UITableViewController, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    var pendingFileURL: URL?
    private var recents: [RecentMovie] = []
    private var progressObservation: NSKeyValueObservation?
    private var importProgress: Progress?
    private var importAlert: UIAlertController?
    private var cancelledImport = false
    private let plex = PlexService()
    private var operation: Task<Void, Never>?
    nonisolated private static var movieDirectory: URL {
        let directory = URL.documentsDirectory.appending(path: "Movies", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = .black
        tableView.backgroundColor = .black
        tableView.tintColor = .systemCyan
        tableView.rowHeight = 64
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "movie")
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 180))
        let title = UILabel(); title.text = "VR Player"; title.font = .systemFont(ofSize: 38, weight: .bold)
        let subtitle = UILabel(); subtitle.text = "Your movies. One clear view."; subtitle.font = .preferredFont(forTextStyle: .body); subtitle.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [title, subtitle]); stack.axis = .vertical; stack.spacing = 10
        header.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24), stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -24)])
        tableView.tableHeaderView = header
        if let data = UserDefaults.standard.data(forKey: "recentMovies") { recents = (try? JSONDecoder().decode([RecentMovie].self, from: data)) ?? [] }
        // Files copied through Finder or device tooling appear without a separate import step.
        let existing = (try? FileManager.default.contentsOfDirectory(at: Self.movieDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in existing where ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) && !recents.contains(where: { $0.managedName == url.lastPathComponent }) {
            recents.append(RecentMovie(id: "managed:\(url.lastPathComponent)", title: url.deletingPathExtension().lastPathComponent, bookmark: nil, managedName: url.lastPathComponent))
        }
        var normalized: [RecentMovie] = []
        for record in recents {
            var updated = record
            if let bookmark = record.bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale),
                   url.deletingLastPathComponent().resolvingSymlinksInPath() == Self.movieDirectory.resolvingSymlinksInPath() {
                    updated = RecentMovie(id: "managed:\(url.lastPathComponent)", title: record.title, bookmark: nil, managedName: url.lastPathComponent)
                }
            }
            if !normalized.contains(where: { $0.id == updated.id || (updated.managedName != nil && $0.managedName == updated.managedName) }) { normalized.append(updated) }
        }
        recents = normalized
        saveRecents()
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 3 : recents.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "Open a movie" : recents.isEmpty ? nil : "Recent movies" }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? "Drag to look around. Pinch to zoom. Tap to reveal controls." : nil
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "movie", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            content.text = ["Photos", "Files", "Plex"][indexPath.row]
            content.secondaryText = ["Choose a video from your library", "Open a movie on your phone or iCloud", "Browse your server’s video libraries"][indexPath.row]
            content.image = UIImage(systemName: ["photo.on.rectangle", "folder", "play.rectangle.on.rectangle"][indexPath.row])
        } else {
            content.text = recents[indexPath.row].title
            content.secondaryText = "Resume movie"
            content.image = UIImage(systemName: "play.circle")
        }
        content.imageProperties.tintColor = .systemCyan
        cell.contentConfiguration = content; cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 0 else { openRecent(recents[indexPath.row]); return }
        switch indexPath.row {
        case 0:
            var configuration = PHPickerConfiguration(photoLibrary: .shared())
            configuration.filter = .videos; configuration.selectionLimit = 1; configuration.preferredAssetRepresentationMode = .current
            let picker = PHPickerViewController(configuration: configuration); picker.delegate = self; present(picker, animated: true)
        case 1:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie], asCopy: false)
            picker.delegate = self; present(picker, animated: true)
        default:
            let controller = UINavigationController(rootViewController: PlexController(service: plex) { [weak self] source in
                self?.dismiss(animated: true) { [weak self] in self?.play(source) }
            })
            present(controller, animated: true)
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        controller.dismiss(animated: true) { [weak self] in self?.openFile(url) }
    }
    func openFile(_ url: URL) {
        guard isViewLoaded, view.window != nil else { pendingFileURL = url; return }
        guard presentedViewController == nil else { return }
        if url.deletingLastPathComponent().resolvingSymlinksInPath() == Self.movieDirectory.resolvingSymlinksInPath() {
            let record = recents.first { $0.managedName == url.lastPathComponent } ?? RecentMovie(id: "managed:\(url.lastPathComponent)", title: url.deletingPathExtension().lastPathComponent, bookmark: nil, managedName: url.lastPathComponent)
            remember(record); openRecent(record); return
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let record = RecentMovie(id: "file:\(url.absoluteString)", title: url.deletingPathExtension().lastPathComponent, bookmark: bookmark, managedName: nil)
            remember(record)
            openRecent(record)
        } catch { showError(error.localizedDescription) }
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self, let result = results.first else { return }
            self.cancelledImport = false
            let alert = UIAlertController(title: "Importing video", message: "Downloading the original video from Photos…", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.cancelledImport = true; self?.importProgress?.cancel() })
            self.importAlert = alert
            self.present(alert, animated: true)
            let provider = result.itemProvider
            let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .movie) == true } ?? UTType.movie.identifier
            let name = UUID().uuidString
            self.importProgress = provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
                // The provider deletes its temporary file after this callback returns.
                let outcome: Result<URL, Error>
                do {
                    guard let url else { throw error ?? PlayerError.message("Photos could not download this video.") }
                    let destination = Self.movieDirectory.appending(path: name).appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: destination)
                    outcome = .success(destination)
                } catch { outcome = .failure(error) }
                Task { @MainActor in
                    guard let self else { return }
                    self.progressObservation = nil
                    if self.cancelledImport {
                        if case .success(let url) = outcome { try? FileManager.default.removeItem(at: url) }
                        return
                    }
                    self.importAlert?.dismiss(animated: true) {
                        switch outcome {
                        case .success(let url):
                            let title = provider.suggestedName ?? "Photos movie"
                            let record = RecentMovie(id: "photo:\(result.assetIdentifier ?? name)", title: title, bookmark: nil, managedName: url.lastPathComponent)
                            self.remember(record); self.openRecent(record)
                        case .failure(let error): self.showError(error.localizedDescription)
                        }
                    }
                }
            }
            self.progressObservation = self.importProgress?.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                Task { @MainActor in self?.importAlert?.message = "Importing original video… \(Int(progress.fractionCompleted * 100))%" }
            }
        }
    }
    private var scopedURL: URL?
    private func openRecent(_ record: RecentMovie) {
        do {
            let url: URL
            if let name = record.managedName { url = Self.movieDirectory.appending(path: name) }
            else if let bookmark = record.bookmark {
                var stale = false
                url = try URL(resolvingBookmarkData: bookmark, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
                if url.startAccessingSecurityScopedResource() { scopedURL = url }
                if stale {
                    let refreshed = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    remember(RecentMovie(id: record.id, title: record.title, bookmark: refreshed, managedName: nil))
                }
            } else { throw PlayerError.message("This movie needs access again. Open it from Files.") }
            play(MovieSource(id: record.id, title: record.title, url: url))
        } catch { showError("Open this movie from Files again.\n\n\(error.localizedDescription)") }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        if let pending = pendingFileURL { pendingFileURL = nil; openFile(pending) }
    }
    private func remember(_ record: RecentMovie) {
        for previous in recents where previous.id == record.id && previous.managedName != record.managedName {
            if let name = previous.managedName { try? FileManager.default.removeItem(at: Self.movieDirectory.appending(path: name)) }
        }
        recents.removeAll { $0.id == record.id || (record.managedName != nil && $0.managedName == record.managedName) }; recents.insert(record, at: 0); saveRecents(); tableView.reloadData()
    }
    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: "recentMovies") }
    }
    private func play(_ source: MovieSource) { present(PlayerController(movie: source), animated: true) }
    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { indexPath.section == 1 }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let record = recents.remove(at: indexPath.row)
        if let name = record.managedName { try? FileManager.default.removeItem(at: Self.movieDirectory.appending(path: name)) }
        saveRecents(); tableView.deleteRows(at: [indexPath], with: .automatic)
    }
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Could not open movie", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
    }
}
