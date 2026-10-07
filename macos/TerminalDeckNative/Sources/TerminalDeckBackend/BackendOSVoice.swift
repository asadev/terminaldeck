import Foundation
import TerminalDeckNativeCore

public enum BackendOSVoiceRules {
    public struct Provider: Sendable {
        public let id: String, label: String, model: String, note: String, endpoint: String, auth: String, modelField: String, keysURL: String
        public var wireValue: NativeRPCValue { .object([.init("id", .string(id)), .init("label", .string(label)), .init("model", .string(model)), .init("note", .string(note)), .init("endpoint", .string(endpoint)), .init("auth", .string(auth)), .init("modelField", .string(modelField)), .init("keysUrl", .string(keysURL))]) }
    }
    public static let providers = [
        Provider(id: "groq", label: "Groq", model: "whisper-large-v3", note: "Whisper large-v3 itself, hosted. Fast, and free at low volume.", endpoint: "https://api.groq.com/openai/v1/audio/transcriptions", auth: "bearer", modelField: "model", keysURL: "https://console.groq.com/keys"),
        Provider(id: "elevenlabs", label: "ElevenLabs Scribe", model: "scribe_v1", note: "Strongest on languages Whisper handles badly, including Urdu.", endpoint: "https://api.elevenlabs.io/v1/speech-to-text", auth: "xi-api-key", modelField: "model_id", keysURL: "https://elevenlabs.io/app/settings/api-keys"),
        Provider(id: "openai", label: "OpenAI", model: "whisper-1", note: "The hosted Whisper. Note it is large-v2, not v3.", endpoint: "https://api.openai.com/v1/audio/transcriptions", auth: "bearer", modelField: "model", keysURL: "https://platform.openai.com/api-keys")
    ]
    public static func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }
    /// voice.ts voiceStatus L413: the store cannot be used here, so a key cannot be kept.
    public static let noSecureStore = "This machine has no secure store, so a key cannot be kept here. On Linux, start a keyring and reopen the app."
    /// voice.ts saveCheckedVoiceKey L166.
    public static let noSecureStoreSaved = "This machine has no secure store available, so the key was not saved. On Linux that usually means no keyring is running; start one and try again."
    public static func transcript(_ body: String) -> String? {
        if let raw = try? NativeRPCValue.parseJSON(Data(body.utf8)) { return raw["text"].string }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines); return trimmed.isEmpty ? nil : trimmed
    }
    public static func failure(status: Int, body: String) -> String {
        let raw = try? NativeRPCValue.parseJSON(Data(body.utf8))
        let detail = raw?["error"].string ?? raw?["error"]["message"].string ?? raw?["message"].string ?? raw?["detail"].string ?? String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        if status == 401 || status == 403 { return "The provider rejected the key" + (detail.isEmpty ? "." : " — " + detail) }
        if status == 429 { return "The provider is rate-limiting this key" + (detail.isEmpty ? "." : " — " + detail) + " Wait a moment and try again." }
        if status >= 500 { return "The provider had a problem of its own (\(status))" + (detail.isEmpty ? "." : " — " + detail) + " Nothing is wrong with the key." }
        return detail.isEmpty ? "The provider answered \(status) and said nothing else." : detail
    }
    public static func silentWav(milliseconds: Int) -> Data {
        let samples = max(1, Int((16_000 * Double(milliseconds) / 1000).rounded())), size = samples * 2
        var data = Data(count: 44 + size)
        func text(_ value: String, _ offset: Int) { data.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8) }
        func u16(_ value: UInt16, _ offset: Int) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + 2), with: $0) } }
        func u32(_ value: UInt32, _ offset: Int) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.replaceSubrange(offset..<(offset + 4), with: $0) } }
        text("RIFF", 0); u32(UInt32(36 + size), 4); text("WAVE", 8); text("fmt ", 12); u32(16, 16); u16(1, 20); u16(1, 22); u32(16_000, 24); u32(32_000, 28); u16(2, 32); u16(16, 34); text("data", 36); u32(UInt32(size), 40)
        return data
    }
    public static func multipart(provider: Provider, audio: Data, filename: String, boundary: String) -> Data {
        let safeName = filename.replacingOccurrences(of: "\r", with: "%0D").replacingOccurrences(of: "\n", with: "%0A").replacingOccurrences(of: "\"", with: "%22")
        var result = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        result.append(audio); result.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"\(provider.modelField)\"\r\n\r\n\(provider.model)\r\n--\(boundary)--\r\n".utf8)); return result
    }
    /// File payload is the exact Electron JSON {provider,key}, encrypted as a
    /// binary Chromium v10 blob by the existing original-service cipher.
    static func encodeKey(provider: String, key: String) throws -> String { String(decoding: try NativeRPCValue.object([.init("provider", .string(provider)), .init("key", .string(key))]).encodedJSON(), as: UTF8.self) }
    static func decodeKey(_ plaintext: String) throws -> (provider: String, key: String) {
        let raw = try NativeRPCValue.parseJSON(Data(plaintext.utf8), maximumBytes: 32_768)
        guard let provider = raw["provider"].string, let key = raw["key"].string, !key.isEmpty else { throw NativeRPCError.malformed("The stored voice key has an unsupported format.") }
        return (provider, key)
    }
}

public protocol BackendOSVoiceEncrypting: Sendable {
    func prepareForWrites(existingVault: Bool) throws
    func encrypt(_ text: String, existingVault: Bool) throws -> Data
    func decrypt(_ blob: Data) throws -> String
}
extension BackendAccountKeychainCipher: BackendOSVoiceEncrypting {}
public protocol BackendOSVoiceRequesting: Sendable {
    func post(provider: BackendOSVoiceRules.Provider, key: String, audio: Data, filename: String) async throws -> (status: Int, body: String)
}
public struct BackendOSVoiceHTTP: BackendOSVoiceRequesting, Sendable {
    public init() {}
    public func post(provider: BackendOSVoiceRules.Provider, key: String, audio: Data, filename: String) async throws -> (status: Int, body: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 20; configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: BackendOSVoiceRedirectGuard(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let boundary = "native-voice-" + UUID().uuidString
        var request = URLRequest(url: URL(string: provider.endpoint)!); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(provider.auth == "bearer" ? "Bearer " + key : key, forHTTPHeaderField: provider.auth == "bearer" ? "Authorization" : "xi-api-key")
        request.httpBody = BackendOSVoiceRules.multipart(provider: provider, audio: audio, filename: filename, boundary: boundary)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw NativeRPCError(code: "network", message: "The provider did not return an HTTP response.") }
        var body = Data(); body.reserveCapacity(32_768)
        for try await byte in bytes { body.append(byte); if body.count > 2 * 1024 * 1024 { throw NativeRPCError.malformed("The transcription response exceeded its read budget.") }; if body.count % 4096 == 0 { try Task.checkCancellation() } }
        return (response.statusCode, String(decoding: body, as: UTF8.self))
    }
}
public actor BackendOSVoiceService {
    public static let channels: Set<String> = ["voice:providers", "voice:status", "voice:save", "voice:forget", "voice:transcribe"]
    public nonisolated let file: URL
    private let cipher: any BackendOSVoiceEncrypting, http: any BackendOSVoiceRequesting
    private let store: NativeStateStore
    private let authorize: @Sendable (NativeRPCContext, String) throws -> Void
    private var active = false
    public init(userData: URL, store: NativeStateStore, cipher: any BackendOSVoiceEncrypting, http: any BackendOSVoiceRequesting = BackendOSVoiceHTTP(),
                authorize: @escaping @Sendable (NativeRPCContext, String) throws -> Void) throws {
        guard userData.isFileURL, userData.path.hasPrefix("/") else { throw NativeRPCError.invalidArguments("Voice storage needs the existing app's absolute data directory.") }
        file = userData.appendingPathComponent("voice-key.bin"); self.store = store; self.cipher = cipher; self.http = http; self.authorize = authorize
    }
    public func activate(oldVoiceOwnerDisabled: Bool) throws {
        guard oldVoiceOwnerDisabled, store.ownership == .exclusive, store.file?.deletingLastPathComponent().standardizedFileURL.path == file.deletingLastPathComponent().standardizedFileURL.path else { throw NativeRPCError(code: "unavailable", message: "The native voice service cannot write while the old voice/state owner is still active.") }; active = true
    }
    private func stored() throws -> (provider: String, key: String)? {
        guard let data = try BackendAccountFiles.boundedRead(file, maximum: 64 * 1024) else { return nil }
        return try BackendOSVoiceRules.decodeKey(cipher.decrypt(data))
    }
    public func status() -> NativeRPCValue {
        do {
            try cipher.prepareForWrites(existingVault: true) // Read-only availability check; never create a key for a read.
        } catch { return .object([.init("provider", .null), .init("hasKey", .bool(false)), .init("canStore", .bool(false)), .init("reason", .string(BackendOSVoiceRules.noSecureStore))]) }
        do {
            let key = try stored()
            return .object([.init("provider", key.map { .string($0.provider) } ?? .null), .init("hasKey", .bool(key != nil)), .init("canStore", .bool(true)), .init("reason", .null)])
        } catch { return .object([.init("provider", .null), .init("hasKey", .bool(false)), .init("canStore", .bool(true)), .init("reason", .string("The stored voice key could not be read. Its encrypted file was kept unchanged: " + error.localizedDescription))]) }
    }
    private static func result(_ ok: Bool, text: String = "", message: String = "") -> NativeRPCValue { .object([.init("ok", .bool(ok)), .init("text", .string(text)), .init("message", .string(message))]) }
    private func transcribe(provider: BackendOSVoiceRules.Provider, key: String, audio: Data, filename: String) async throws -> NativeRPCValue {
        guard key.rangeOfCharacter(from: .controlCharacters) == nil, key.utf8.count <= 16_384 else { return Self.result(false, message: "The provider key is not a valid single-line key.") }
        guard audio.count <= 64 * 1024 * 1024 else { return Self.result(false, message: "The recording exceeds this native bridge's 64 MiB audio budget.") }
        do {
            let answer = try await http.post(provider: provider, key: key, audio: audio, filename: filename)
            guard (200..<300).contains(answer.status) else { return Self.result(false, message: BackendOSVoiceRules.failure(status: answer.status, body: answer.body).replacingOccurrences(of: key, with: "[redacted key]")) }
            guard let text = BackendOSVoiceRules.transcript(answer.body) else { return Self.result(false, message: "The provider answered, but not with a transcript this build understands.") }
            return Self.result(true, text: text)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { return Self.result(false, message: "The provider did not answer within twenty seconds. Try again.") }
        catch { try Task.checkCancellation(); return Self.result(false, message: "Could not reach the provider — " + error.localizedDescription.replacingOccurrences(of: key, with: "[redacted key]")) }
    }
    public func save(providerID: String, key rawKey: String) async throws -> NativeRPCValue {
        guard active else { throw NativeRPCError(code: "unavailable", message: "The native voice writer has not taken ownership.") }
        guard let provider = BackendOSVoiceRules.provider(providerID) else { return .object([.init("ok", .bool(false)), .init("message", .string("Pick a provider first."))]) }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .object([.init("ok", .bool(false)), .init("message", .string("Paste a key first."))]) }
        let check = try await transcribe(provider: provider, key: key, audio: BackendOSVoiceRules.silentWav(milliseconds: 200), filename: "check.wav")
        try Task.checkCancellation()
        guard check["ok"].bool == true else { return check.removing("text") }
        let existing = FileManager.default.fileExists(atPath: file.path)
        // voice.ts saveCheckedVoiceKey L162-166: no usable secure store is said in
        // the app's own words, never as the Keychain's status sentence.
        let blob: Data
        do {
            try cipher.prepareForWrites(existingVault: existing)
            blob = try cipher.encrypt(BackendOSVoiceRules.encodeKey(provider: provider.id, key: key), existingVault: existing)
        } catch { return .object([.init("ok", .bool(false)), .init("message", .string(BackendOSVoiceRules.noSecureStoreSaved))]) }
        do {
            guard blob.starts(with: Data("v10".utf8)) else { throw NativeRPCError.malformed("The voice cipher did not return the existing Chromium v10 file format.") }
            try BackendAccountFiles.writeAtomic(blob, to: file)
        } catch { return .object([.init("ok", .bool(false)), .init("message", .string("The key was accepted but could not be securely saved: " + error.localizedDescription))]) }
        return .object([.init("ok", .bool(true)), .init("message", .string("\(provider.label) accepted the key and answered with \(provider.model)."))])
    }
    public func forget() throws { guard active else { throw NativeRPCError(code: "unavailable", message: "The native voice writer has not taken ownership.") }; if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) } }
    public func transcribeStored(audio: Data?, filename: String?) async throws -> NativeRPCValue {
        let stored = try stored()
        guard let stored else { return Self.result(false, message: "No transcription key is set.") }
        guard let provider = BackendOSVoiceRules.provider(stored.provider) else { return Self.result(false, message: "The stored key is for a provider this build does not have.") }
        guard let audio else { return Self.result(false, message: "No audio arrived.") }
        return try await transcribe(provider: provider, key: stored.key, audio: audio, filename: filename.flatMap { $0.isEmpty ? nil : $0 } ?? "speech.webm")
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw NativeRPCError(code: "unavailable", message: "The native voice channel is not registered.") }
        try authorize(context, channel); try Task.checkCancellation()
        let value = args.first ?? .missing
        switch channel {
        case "voice:providers": return .array(BackendOSVoiceRules.providers.map(\.wireValue))
        case "voice:status": return status()
        case "voice:save": return try await save(providerID: value["provider"].string ?? "", key: value["key"].string ?? "")
        case "voice:forget": try forget(); return .object([.init("ok", .bool(true)), .init("message", .string("Key removed. The microphone goes with it."))])
        case "voice:transcribe": let audio: Data? = { if case .bytes(let bytes) = value["audio"] { return bytes }; return nil }(); return try await transcribeStored(audio: audio, filename: value["filename"].string)
        default: throw NativeRPCError(code: "unavailable", message: "The native voice operation is unsupported.")
        }
    }
}

final class BackendOSVoiceRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func allowed(original: URL?, target: URL?) -> Bool {
        guard let original, let target else { return false }
        return target.scheme == "https" && original.scheme == target.scheme && original.host?.lowercased() == target.host?.lowercased() && (original.port ?? 443) == (target.port ?? 443)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowed(original: task.originalRequest?.url, target: request.url) ? request : nil)
    }
}
