import Foundation
import CoreGraphics

struct ViewState: Codable, Equatable {
    var yaw: Float = 0
    var pitch: Float = 0
    var fieldOfView: Float = 80
    var rightEye = false
    var fisheye = false

    mutating func constrain(aspect: Float) {
        fieldOfView = min(100, max(25, fieldOfView))
        let halfVertical = fieldOfView * .pi / 360
        let halfHorizontal = atan(tan(halfVertical) * max(0.1, aspect))
        let yawLimit = max(0, Float.pi / 2 - halfHorizontal)
        let pitchLimit = max(0, Float.pi / 2 - halfVertical)
        yaw = min(yawLimit, max(-yawLimit, yaw))
        pitch = min(pitchLimit, max(-pitchLimit, pitch))
        // Both axes together can move a corner behind the recorded hemisphere.
        let desiredYaw = yaw, desiredPitch = pitch
        if !cornersFaceVideo(aspect: aspect) {
            var low: Float = 0, high: Float = 1
            for _ in 0..<16 {
                let fraction = (low + high) / 2
                yaw = desiredYaw * fraction; pitch = desiredPitch * fraction
                if cornersFaceVideo(aspect: aspect) { low = fraction } else { high = fraction }
            }
            yaw = desiredYaw * low; pitch = desiredPitch * low
        }
    }
    func ray(x: Float, y: Float, aspect: Float) -> SIMD3<Float> {
        let tangent = tan(fieldOfView * .pi / 360)
        let r = SIMD3(x * tangent * aspect, y * tangent, -1)
        let pitched = SIMD3(r.x, cos(pitch) * r.y - sin(pitch) * r.z, sin(pitch) * r.y + cos(pitch) * r.z)
        let rotated = SIMD3(cos(yaw) * pitched.x - sin(yaw) * pitched.z, pitched.y, sin(yaw) * pitched.x + cos(yaw) * pitched.z)
        return rotated / sqrt(rotated.x * rotated.x + rotated.y * rotated.y + rotated.z * rotated.z)
    }
    func cornersFaceVideo(aspect: Float) -> Bool {
        [-1, 1].allSatisfy { x in [-1, 1].allSatisfy { y in ray(x: Float(x), y: Float(y), aspect: aspect).z <= -0.0001 } }
    }
    func textureCoordinate(direction: SIMD3<Float>) -> SIMD2<Float> {
        let u = 0.5 + atan2(direction.x, -direction.z) / .pi
        let v = 0.5 - asin(min(1, max(-1, direction.y))) / .pi
        return SIMD2((u + (rightEye ? 1 : 0)) * 0.5, v)
    }
}

struct SavedPlayback: Codable {
    var seconds: Double
    var view: ViewState
}

struct PlaybackHistory {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load(_ key: String) -> SavedPlayback? {
        guard let data = defaults.data(forKey: "playback:\(key)") else { return nil }
        return try? JSONDecoder().decode(SavedPlayback.self, from: data)
    }
    func save(_ key: String, seconds: Double, view: ViewState) {
        guard seconds.isFinite, seconds >= 0,
              let data = try? JSONEncoder().encode(SavedPlayback(seconds: seconds, view: view)) else { return }
        defaults.set(data, forKey: "playback:\(key)")
    }
}
