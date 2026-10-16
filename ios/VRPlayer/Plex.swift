import Foundation
import AVFoundation
import Security

struct PlexConnection: Decodable, Hashable {
    let uri: String
    let local: Bool?
    let relay: Bool?
}
struct PlexServer: Decodable, Identifiable {
    let name: String
    let clientIdentifier: String
    let provides: String
    let accessToken: String?
    let connections: [PlexConnection]
    var id: String { clientIdentifier }
}
struct PlexLibrary: Decodable, Identifiable {
    let key: String
    let title: String
    let type: String
    var id: String { key }
}
struct PlexPart: Decodable { let key: String? }
struct PlexMedia: Decodable {
    let width: Int?
    let height: Int?
    let videoCodec: String?
    let audioCodec: String?
    let videoDecision: String?
    let Part: [PlexPart]?
}
struct PlexMovie: Decodable, Identifiable {
    let ratingKey: String
    let title: String
    let year: Int?
    let duration: Int?
    let Media: [PlexMedia]?
    var id: String { ratingKey }
}
struct PlexContainer: Decodable {
    let Directory: [PlexLibrary]?
    let Metadata: [PlexMovie]?
    let totalSize: Int?
    let size: Int?
    let generalDecisionText: String?
    let transcodeDecisionText: String?
}
struct PlexResponse: Decodable { let MediaContainer: PlexContainer }
struct PlexPin: Decodable { let id: Int; let code: String; let authToken: String? }

struct PlexPlaybackContext {
    let service: PlexService
    let server: PlexServer
    let baseURL: URL
    let movie: PlexMovie
    let sessionID: String
    func stopSession() async { await service.stopSession(self) }
}

struct PlexStreamDecision {
    static func requiresVideoConversion(_ media: PlexMedia?) -> Bool {
        media?.videoDecision?.lowercased() == "transcode"
    }
    static func validateCopy(_ media: PlexMedia?, original: PlexMedia?) throws {
        guard let media, let decision = media.videoDecision?.lowercased(), ["copy", "directplay"].contains(decision) else {
            throw PlayerError.message("Plex requires video conversion for this movie. Your original quality has not changed.")
        }
        if let width = original?.width, let outputWidth = media.width, outputWidth != width {
            throw PlayerError.message("Plex changed the stereo picture dimensions. Playback stopped to protect the view.")
        }
        if let height = original?.height, let outputHeight = media.height, outputHeight != height {
            throw PlayerError.message("Plex changed the stereo picture dimensions. Playback stopped to protect the view.")
        }
    }
}

struct CredentialStore {
    static let service = "com.mikepearlman.vrplayer.plex"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String?) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        guard let token else { return }
        var entry = query
        entry[kSecValueData as String] = Data(token.utf8)
        entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(entry as CFDictionary, nil)
        guard status == errSecSuccess else { throw PlayerError.message("Plex sign-in could not save your access securely.") }
    }
}

final class PlexService: @unchecked Sendable {
    let clientID: String
    var token: String? { CredentialStore.read() }
    init() {
        if let id = UserDefaults.standard.string(forKey: "plexClientID") { clientID = id }
        else { clientID = UUID().uuidString; UserDefaults.standard.set(clientID, forKey: "plexClientID") }
    }
    private func request<T: Decodable>(_ url: URL, token: String? = nil, method: String = "GET") async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VR Player", forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PlayerError.message("Plex returned an invalid response.") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw PlayerError.message("Plex access expired. Sign in again.") }
            throw PlayerError.message("Plex returned error \(response.statusCode). Check your server connection.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func createPin() async throws -> PlexPin {
        try await request(URL(string: "https://plex.tv/api/v2/pins?strong=true")!, method: "POST")
    }
    func pollPin(_ pin: PlexPin) async throws {
        for _ in 0..<150 {
            try Task.checkCancellation()
            let result: PlexPin = try await request(URL(string: "https://plex.tv/api/v2/pins/\(pin.id)?code=\(pin.code)")!)
            if let token = result.authToken { try CredentialStore.save(token); return }
            try await Task.sleep(for: .seconds(2))
        }
        throw PlayerError.message("Plex sign-in expired. Try again.")
    }
    func authenticationURL(_ pin: PlexPin) -> URL {
        var fragment = URLComponents()
        fragment.queryItems = [URLQueryItem(name: "clientID", value: clientID), URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: "VR Player"), URLQueryItem(name: "forwardUrl", value: "vrplayer://plex")]
        return URL(string: "https://app.plex.tv/auth#?\(fragment.percentEncodedQuery!)")!
    }
    func servers() async throws -> [PlexServer] {
        guard let token else { throw PlayerError.message("Sign in to Plex first.") }
        let resources: [PlexServer] = try await request(URL(string: "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1")!, token: token)
        return resources.filter { $0.provides.split(separator: ",").contains("server") }
    }
    func connect(_ server: PlexServer) async throws -> URL {
        let connections = server.connections.sorted { lhs, rhs in
            func score(_ c: PlexConnection) -> Int { (c.local == true ? 4 : 0) + (c.uri.hasPrefix("https:") ? 2 : 0) - (c.relay == true ? 8 : 0) }
            return score(lhs) > score(rhs)
        }
        for connection in connections {
            try Task.checkCancellation()
            guard let url = URL(string: connection.uri), ["http", "https"].contains(url.scheme ?? "") else { continue }
            do {
                var request = URLRequest(url: endpoint(url, "/identity"))
                request.timeoutInterval = 4
                request.setValue(server.accessToken ?? token, forHTTPHeaderField: "X-Plex-Token")
                let (_, response) = try await URLSession.shared.data(for: request)
                if let response = response as? HTTPURLResponse, response.statusCode == 200 { return url }
            } catch is CancellationError { throw CancellationError() } catch { continue }
        }
        throw PlayerError.message("Your Plex server cannot connect. Check its network and remote access.")
    }
    func libraries(_ server: PlexServer, base: URL) async throws -> [PlexLibrary] {
        let result: PlexResponse = try await request(endpoint(base, "/library/sections"), token: server.accessToken ?? token)
        return (result.MediaContainer.Directory ?? []).filter { ["movie", "show", "artist", "photo"].contains($0.type) && $0.type != "artist" && $0.type != "photo" }
    }
    func movies(_ server: PlexServer, base: URL, library: PlexLibrary, search: String, start: Int) async throws -> PlexContainer {
        var items = [URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "X-Plex-Container-Start", value: String(start)),
                     URLQueryItem(name: "X-Plex-Container-Size", value: "100"), URLQueryItem(name: "sort", value: "titleSort")]
        if library.type == "show" { items[0].value = "4" }
        if !search.isEmpty { items.append(URLQueryItem(name: "title", value: search)) }
        let result: PlexResponse = try await request(endpoint(base, "/library/sections/\(library.key)/all", query: items), token: server.accessToken ?? token)
        return result.MediaContainer
    }
    func movieSource(_ server: PlexServer, base: URL, movie: PlexMovie) async throws -> MovieSource {
        let result: PlexResponse = try await request(endpoint(base, "/library/metadata/\(movie.ratingKey)"), token: server.accessToken ?? token)
        guard let full = result.MediaContainer.Metadata?.first, let part = full.Media?.first?.Part?.first?.key else {
            throw PlayerError.message("Plex could not find the movie file.")
        }
        let context = PlexPlaybackContext(service: self, server: server, baseURL: base, movie: full, sessionID: UUID().uuidString)
        return MovieSource(id: "plex:\(server.id):\(movie.id)", title: movie.title,
            url: endpoint(base, part, query: [URLQueryItem(name: "X-Plex-Token", value: server.accessToken ?? token)]), plex: context)
    }
    func convertedSource(_ source: MovieSource, allowVideoConversion: Bool) async throws -> MovieSource {
        guard let context = source.plex else { throw PlayerError.message("This movie has no Plex connection.") }
        let original = context.movie.Media?.first
        var query = [
            URLQueryItem(name: "path", value: "/library/metadata/\(context.movie.id)"),
            URLQueryItem(name: "mediaIndex", value: "0"), URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"), URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"), URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "subtitles", value: "none"), URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "videoQuality", value: "100"), URLQueryItem(name: "maxVideoBitrate", value: "200000"),
            URLQueryItem(name: "session", value: context.sessionID), URLQueryItem(name: "X-Plex-Platform", value: "iOS"),
            URLQueryItem(name: "X-Plex-Product", value: "VR Player"), URLQueryItem(name: "X-Plex-Client-Identifier", value: clientID),
            URLQueryItem(name: "X-Plex-Token", value: context.server.accessToken ?? token)
        ]
        if let width = original?.width, let height = original?.height {
            query.append(URLQueryItem(name: "videoResolution", value: "\(width)x\(height)"))
        }
        if allowVideoConversion {
            query.append(URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac)"))
        }
        let decision: PlexResponse = try await request(endpoint(context.baseURL, "/video/:/transcode/universal/decision", query: query), token: context.server.accessToken ?? token)
        let media = decision.MediaContainer.Metadata?.first?.Media?.first
        if !allowVideoConversion { try PlexStreamDecision.validateCopy(media, original: original) }
        if let w = media?.width, let h = media?.height, let ow = original?.width, let oh = original?.height,
           abs(Double(w) / Double(h) - Double(ow) / Double(oh)) > 0.01 {
            throw PlayerError.message("Plex would distort the stereo picture. Playback stopped.")
        }
        var next = source
        next.url = endpoint(context.baseURL, "/video/:/transcode/universal/start.m3u8", query: query)
        return next
    }
    func stopSession(_ context: PlexPlaybackContext) async {
        let url = endpoint(context.baseURL, "/video/:/transcode/universal/stop", query: [
            URLQueryItem(name: "session", value: context.sessionID), URLQueryItem(name: "X-Plex-Token", value: context.server.accessToken ?? token)])
        _ = try? await URLSession.shared.data(from: url)
    }
    func endpoint(_ base: URL, _ path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        // Plex supplies rooted part keys. Preserve any query already present in that key.
        let supplied = URLComponents(string: path)
        parts.path = supplied?.path ?? path
        parts.queryItems = (supplied?.queryItems ?? []) + query
        return parts.url!
    }
}
