import UIKit
import AuthenticationServices

@MainActor
final class PlexController: UITableViewController, ASWebAuthenticationPresentationContextProviding, UISearchResultsUpdating {
    let service: PlexService
    let openMovie: (MovieSource) -> Void
    private var servers: [PlexServer] = []
    private var libraries: [PlexLibrary] = []
    private var movies: [PlexMovie] = []
    private var server: PlexServer?
    private var base: URL?
    private var library: PlexLibrary?
    private var total = 0
    private var loading = false
    private var task: Task<Void, Never>?
    private var auth: ASWebAuthenticationSession?
    private let search = UISearchController(searchResultsController: nil)
    private var status = ""
    init(service: PlexService, openMovie: @escaping (MovieSource) -> Void) {
        self.service = service; self.openMovie = openMovie; super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); overrideUserInterfaceStyle = .dark; title = "Plex"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.task?.cancel(); self?.auth?.cancel(); self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Sign out", primaryAction: UIAction { [weak self] _ in self?.signOut() })
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false; search.searchBar.placeholder = "Search movies"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "item")
        refreshControl = UIRefreshControl(); refreshControl?.addTarget(self, action: #selector(reloadCurrent), for: .valueChanged)
        if service.token == nil { signIn() } else { loadServers() }
    }
    private func signOut() {
        task?.cancel(); auth?.cancel(); try? CredentialStore.save(nil)
        server = nil; library = nil; base = nil; servers = []; libraries = []; movies = []; status = "Tap Sign in to connect your Plex account."
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Sign in", primaryAction: UIAction { [weak self] _ in self?.signIn() })
        tableView.reloadData()
    }
    private func signIn() {
        run("Signing in to Plex…") {
            let pin = try await self.service.createPin()
            self.auth = ASWebAuthenticationSession(url: self.service.authenticationURL(pin), callbackURLScheme: "vrplayer") { [weak self] _, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin, self?.service.token == nil {
                    Task { @MainActor in self?.task?.cancel(); self?.loading = false; self?.status = "Sign-in cancelled. Pull to try again."; self?.tableView.reloadData() }
                }
            }
            self.auth?.presentationContextProvider = self
            guard self.auth?.start() == true else { throw PlayerError.message("Plex sign-in could not open.") }
            try await self.service.pollPin(pin)
            self.auth?.cancel(); self.auth = nil
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Sign out", primaryAction: UIAction { [weak self] _ in self?.signOut() })
            self.servers = try await self.service.servers()
            self.status = self.servers.isEmpty ? "Plex returned no available servers." : "Choose a server"
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { view.window! }
    private func loadServers() {
        run("Finding your servers…") {
            self.servers = try await self.service.servers()
            self.status = self.servers.isEmpty ? "Plex returned no available servers." : "Choose a server"
        }
    }
    private func choose(_ server: PlexServer) {
        run("Connecting to \(server.name)…") {
            let base = try await self.service.connect(server)
            self.libraries = try await self.service.libraries(server, base: base)
            self.server = server; self.base = base
            self.title = server.name
            self.status = self.libraries.isEmpty ? "This server has no video libraries." : "Choose a library"
            self.navigationItem.backBarButtonItem = UIBarButtonItem(title: "Servers", style: .plain, target: nil, action: nil)
            self.navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Servers", primaryAction: UIAction { [weak self] _ in
                self?.server = nil; self?.base = nil; self?.library = nil; self?.title = "Plex"; self?.loadServers()
            })
        }
    }
    private func loadMovies(reset: Bool) {
        guard let server, let base, let library else { return }
        let searchText = search.searchBar.text ?? ""
        run("Loading movies…") {
            let start = reset ? 0 : self.movies.count
            let response = try await self.service.movies(server, base: base, library: library, search: searchText, start: start)
            try Task.checkCancellation()
            if reset { self.movies = [] }
            self.movies += response.Metadata ?? []
            self.total = response.totalSize ?? (self.movies.count + ((response.Metadata?.count ?? 0) == 100 ? 1 : 0))
            self.status = self.movies.isEmpty ? "No matching movies." : "\(self.movies.count) movies"
        }
    }
    private func run(_ message: String, operation: @escaping () async throws -> Void) {
        task?.cancel(); loading = true; status = message; tableView.reloadData()
        task = Task {
            do { try await operation(); try Task.checkCancellation() }
            catch is CancellationError { return }
            catch { if Task.isCancelled { return }; self.status = error.localizedDescription }
            self.loading = false; self.refreshControl?.endRefreshing(); self.updateNavigation(); self.tableView.reloadData()
        }
    }
    private func updateNavigation() {
        if library != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Libraries", primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.task?.cancel(); self.loading = false; self.library = nil; self.movies = []
                self.navigationItem.searchController = nil; self.title = self.server?.name
                self.status = "Choose a library"; self.updateNavigation(); self.tableView.reloadData()
            })
        } else if server != nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Servers", primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.server = nil; self.base = nil; self.libraries = []; self.title = "Plex"; self.loadServers()
            })
        } else {
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: service.token == nil ? "Sign in" : "Sign out", primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                if self.service.token == nil { self.signIn() } else { self.signOut() }
            })
        }
    }
    @objc private func reloadCurrent() {
        if service.token == nil { signIn() }
        else if library != nil { loadMovies(reset: true) }
        else if let server { choose(server) }
        else { loadServers() }
    }
    func updateSearchResults(for searchController: UISearchController) {
        guard library != nil else { return }
        task?.cancel()
        task = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            loadMovies(reset: true)
        }
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { status }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if library != nil { return movies.count + (movies.count < total ? 1 : 0) }
        if server != nil { return libraries.count }
        return servers.count
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "item", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if library != nil {
            if indexPath.row == movies.count { content.text = "Load more movies"; content.image = UIImage(systemName: "ellipsis") }
            else { let movie = movies[indexPath.row]; content.text = movie.title; content.secondaryText = movie.year.map(String.init); content.image = UIImage(systemName: "film") }
        } else if server != nil { content.text = libraries[indexPath.row].title; content.image = UIImage(systemName: "folder") }
        else { content.text = servers[indexPath.row].name; content.image = UIImage(systemName: "externaldrive.connected.to.line.below") }
        cell.contentConfiguration = content; cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !loading else { return }
        if library != nil, let server, let base {
            if indexPath.row == movies.count { loadMovies(reset: false); return }
            let movie = movies[indexPath.row]
            run("Opening \(movie.title)…") { self.openMovie(try await self.service.movieSource(server, base: base, movie: movie)) }
        } else if server != nil {
            library = libraries[indexPath.row]; title = library?.title; navigationItem.searchController = search
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Libraries", primaryAction: UIAction { [weak self] _ in
                self?.task?.cancel(); self?.loading = false; self?.library = nil; self?.movies = []; self?.navigationItem.searchController = nil
                self?.title = self?.server?.name; self?.status = "Choose a library"; self?.tableView.reloadData()
            })
            loadMovies(reset: true)
        } else { choose(servers[indexPath.row]) }
    }
}
