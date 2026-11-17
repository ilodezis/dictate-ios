import AVFoundation
import Foundation
import Security

struct DictateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The microphone, kept running for the whole session: iOS lets a backgrounded app go on recording,
/// never start. Samples are kept only between `begin` and `end`.
final class Recorder {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var capturing = false
    private(set) var sampleRate: Double = 48_000
    /// Called on the main thread with each buffer's level while capturing.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        // mixWithOthers: music and podcasts keep playing while the session waits.
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw DictateError(L("NoticeNoMicrophone")) }
        sampleRate = format.sampleRate
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func begin() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            capturing = true
        }
    }

    func end() -> [Float] {
        lock.withLock {
            capturing = false
            defer { samples = [] }
            return samples
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        let kept = lock.withLock {
            if capturing { samples.append(contentsOf: chunk) }
            return capturing
        }
        guard kept, let onLevel else { return }
        let level = rms(chunk)
        DispatchQueue.main.async { onLevel(level) }
    }
}

enum Encoder {
    /// Mono AAC in an m4a: a tenth of the wav size, and what the worker expects.
    static func m4a(_ samples: ArraySlice<Float>, sampleRate: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "take-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try write(samples, sampleRate: sampleRate, to: url)
        return try Data(contentsOf: url)
    }

    /// The file is finished when it goes out of scope here.
    private static func write(_ samples: ArraySlice<Float>, sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
            let channel = buffer.floatChannelData?[0]
        else { throw DictateError(L("NoticeEncodeFailed")) }
        buffer.frameLength = count
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        try file.write(from: buffer)
    }
}

/// The worker: `POST /v1/dictate` for text, `/v1/vocabulary` for the dictionary.
struct Transcriber {
    let base: URL
    let token: String

    /// Server and token from settings, or an error that says what is missing.
    static func current() throws -> Transcriber {
        let server = UserDefaults.standard.string(forKey: "server") ?? ""
        guard let base = URL(string: server), base.scheme == "https", base.host() != nil else {
            throw DictateError(L("NoticeNoServer"))
        }
        guard let token = Keychain.token else { throw DictateError(L("NoticeNoToken")) }
        return Transcriber(base: base, token: token)
    }

    private struct Reply: Decodable {
        var text: String?
        var terms: [String]?
        var error: String?
    }

    func send(_ audio: Data) async throws -> String {
        let boundary = "dictate-\(UUID().uuidString)"
        var request = URLRequest(url: base.appending(path: "v1/dictate"), timeoutInterval: 40)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = multipartBody(
            boundary: boundary, field: "audio", filename: "voice.m4a", contentType: "audio/mp4", data: audio)
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let reply = try check(data, response)
        guard let text = reply.text else { throw DictateError("HTTP 200 without text") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GET lists the dictionary, POST adds a term, DELETE removes one; every call answers with the whole list.
    func vocabulary(_ method: String, term: String? = nil) async throws -> [String] {
        var request = URLRequest(url: base.appending(path: "v1/vocabulary"), timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let term {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(["term": term])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let terms = try check(data, response).terms else { throw DictateError("HTTP 200 without terms") }
        return terms
    }

    private func check(_ data: Data, _ response: URLResponse) throws -> Reply {
        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let reply else { throw DictateError("HTTP \(status) \(reply?.error ?? "")") }
        return reply
    }
}

/// The token stays in the app's keychain: the keyboard never talks to the worker.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "dictate",
        kSecAttrAccount as String: "token",
    ]

    static var token: String? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard SecItemCopyMatching(search as CFDictionary, &found) == errSecSuccess, let data = found as? Data,
            let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    static func save(_ token: String) {
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        // Readable on a locked phone after the first unlock.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// Dictations that did not reach the worker: kept as audio until they are sent again.
enum FailedStore {
    static var folder: URL { URL.applicationSupportDirectory.appending(path: "failed", directoryHint: .isDirectory) }

    static func all() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func save(_ audio: Data) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = String(format: "%.0f.m4a", Date().timeIntervalSince1970 * 1000)
        try audio.write(to: folder.appending(path: name))
    }
}
