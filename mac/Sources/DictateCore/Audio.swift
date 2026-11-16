import Foundation

public func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
    guard !samples.isEmpty else { return 0 }
    return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
}

/// Cuts silence off both ends, keeping a short margin: the Whisper family hallucinates on silence.
public func trimSilence(
    _ samples: [Float], sampleRate: Double, threshold: Float = 0.012, marginMs: Int = 120
) -> ArraySlice<Float> {
    let window = max(1, Int(sampleRate) / 100)  // 10 ms
    let count = samples.count / window
    let loud = (0..<count).filter { rms(samples[($0 * window)..<(($0 + 1) * window)]) > threshold }
    guard let first = loud.first, let last = loud.last else { return [] }
    let margin = max(1, marginMs * Int(sampleRate) / 1000 / window)
    return samples[(max(0, first - margin) * window)..<(min(count, last + 1 + margin) * window)]
}

/// One file field as multipart/form-data, the shape the worker reads with `request.formData()`.
public func multipartBody(boundary: String, field: String, filename: String, contentType: String, data: Data) -> Data {
    var body = Data(
        "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8
    )
    body.append(data)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
}
