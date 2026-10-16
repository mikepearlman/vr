import XCTest
@testable import VRPlayer

final class PlaybackTests: XCTestCase {
    func testStereoEyeCoordinates() {
        let state = ViewState()
        let center = state.textureCoordinate(direction: SIMD3(0, 0, -1))
        XCTAssertEqual(center.x, 0.25, accuracy: 0.00001)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.00001)
        var right = state; right.rightEye = true
        XCTAssertEqual(right.textureCoordinate(direction: SIMD3(0, 0, -1)).x, 0.75, accuracy: 0.00001)
        let leftEdge = state.textureCoordinate(direction: SIMD3(-1, 0, 0))
        let rightEdge = state.textureCoordinate(direction: SIMD3(1, 0, 0))
        XCTAssertEqual(leftEdge.x, 0, accuracy: 0.00001)
        XCTAssertEqual(rightEdge.x, 0.5, accuracy: 0.00001)
    }
    func testZoomAndViewLimits() {
        var state = ViewState(yaw: 100, pitch: -100, fieldOfView: 200)
        state.constrain(aspect: 2.2)
        XCTAssertEqual(state.fieldOfView, 100)
        XCTAssertLessThan(state.yaw, .pi / 2)
        XCTAssertGreaterThan(state.pitch, -.pi / 2)
        XCTAssertGreaterThanOrEqual(state.yaw, 0)
        XCTAssertTrue(state.cornersFaceVideo(aspect: 2.2))
        state.fieldOfView = 0
        state.constrain(aspect: 0.45)
        XCTAssertEqual(state.fieldOfView, 25)
    }
    func testHistoryKeepsPositionAndViewWithoutAcceptingInvalidTime() {
        let name = "VRPlaybackTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let history = PlaybackHistory(defaults: defaults)
        let state = ViewState(yaw: 0.3, pitch: -0.2, fieldOfView: 50, rightEye: true, fisheye: true)
        history.save("movie", seconds: 123.5, view: state)
        XCTAssertEqual(history.load("movie")?.seconds, 123.5)
        XCTAssertEqual(history.load("movie")?.view, state)
        history.save("movie", seconds: .nan, view: ViewState())
        XCTAssertEqual(history.load("movie")?.seconds, 123.5)
        XCTAssertNil(history.load("other"))
    }
    func testPlexResponseAndVideoConversionGate() throws {
        let json = #"{"MediaContainer":{"Metadata":[{"ratingKey":"42","title":"VR Movie","Media":[{"width":7680,"height":3840,"videoCodec":"hevc","videoDecision":"copy","Part":[{"key":"/library/parts/1/file.mp4"}]}]}],"totalSize":1}}"#
        let response = try JSONDecoder().decode(PlexResponse.self, from: Data(json.utf8))
        let movie = try XCTUnwrap(response.MediaContainer.Metadata?.first)
        XCTAssertEqual(movie.title, "VR Movie")
        XCTAssertEqual(movie.Media?.first?.Part?.first?.key, "/library/parts/1/file.mp4")
        XCTAssertNoThrow(try PlexStreamDecision.validateCopy(movie.Media?.first, original: movie.Media?.first))
        let converted = PlexMedia(width: 3840, height: 1920, videoCodec: "h264", audioCodec: "aac", videoDecision: "transcode", Part: nil)
        XCTAssertTrue(PlexStreamDecision.requiresVideoConversion(converted))
        XCTAssertThrowsError(try PlexStreamDecision.validateCopy(converted, original: movie.Media?.first))
        XCTAssertThrowsError(try PlexStreamDecision.validateCopy(nil, original: nil))
        let scaledCopy = PlexMedia(width: 100, height: 100, videoCodec: "hevc", audioCodec: nil, videoDecision: "copy", Part: nil)
        XCTAssertThrowsError(try PlexStreamDecision.validateCopy(scaledCopy, original: movie.Media?.first))
    }
    func testPlexEndpointEscapesTokensAndPreservesRoot() {
        let service = PlexService()
        let url = service.endpoint(URL(string: "https://server.plex.direct:32400")!, "/library/parts/42/file.mp4", query: [URLQueryItem(name: "X-Plex-Token", value: "secret&x=1")])
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(components.path, "/library/parts/42/file.mp4")
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertEqual(components.queryItems?.first?.value, "secret&x=1")
    }
}
