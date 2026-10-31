import AppKit
import CoreVideo
import ImageIO
import IOSurface
import Metal
import TerminalDeckNativeCore

// Finding 3, part B: the Android emulator's direct path (`EmulatorDirect.swift` has the wire rules).
// Everything here is public API (sockets, mmap, Metal) and runs in the app; every reply is read
// defensively, and any surprise ends the direct path, so the panel goes back to the device engine's video (screenrecord).
// Physical Android phones have no shared-memory path anywhere and always show the device engine's video (screenrecord).

/// The emulator's pictures: a file this app owns and maps, which the emulator writes each frame into;
/// the GPU reads it in place (no copy on the CPU), turns it the right way up, and writes the device's
/// screen surface the panel shows.
final class EmulatorFrames: @unchecked Sendable {
    let file: URL
    private let mapping: UnsafeMutableRawPointer
    private let mappedLength: Int
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLComputePipelineState
    private let buffer: any MTLBuffer
    private var cache: CVMetalTextureCache?
    private let lock = NSLock()
    private(set) var width = 0
    private(set) var height = 0
    private var source: (any MTLTexture)?
    private var target: CVPixelBuffer?
    private var targetTexture: CVMetalTexture?
    /// The emulator's rows run bottom up (decided once against a PNG of the same screen).
    private var rowsBottomUp = false
    var flipped: Bool {
        get { lock.withLock { rowsBottomUp } }
        set { lock.withLock { rowsBottomUp = newValue } }
    }
    private var busy = false
    private var again = false

    private static let kernel = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void terminaldeck_emulator_frame(texture2d<float, access::read> source [[texture(0)]],
                                            texture2d<float, access::write> target [[texture(1)]],
                                            constant uint &flip [[buffer(0)]],
                                            uint2 at [[thread_position_in_grid]]) {
        if (at.x >= target.get_width() || at.y >= target.get_height()) return;
        uint row = flip != 0 ? source.get_height() - 1 - at.y : at.y;
        target.write(float4(source.read(uint2(at.x, row)).rgb, 1.0), at);
    }
    """

    /// A mapped file big enough for the screen's pixels either way up.
    init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 8_192, height <= 8_192,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw EmulatorDirectError("No GPU for the emulator's pictures.")
        }
        // The GPU step first: nothing to undo if it cannot be made.
        let library = try device.makeLibrary(source: Self.kernel, options: nil)
        guard let function = library.makeFunction(name: "terminaldeck_emulator_frame") else {
            throw EmulatorDirectError("The emulator picture step is missing.")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        let page = Int(getpagesize())
        let length = (width * height * 4 + page - 1) / page * page
        let folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Named after this process, so a later panel can tell a file whose maker has ended (a crash) from a live one.
        let file = folder.appendingPathComponent(EmulatorFrameFiles.name(pid: getpid(), id: UUID()))
        let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw EmulatorDirectError("No picture file for the emulator.") }
        defer { Darwin.close(fd) }
        guard ftruncate(fd, off_t(length)) == 0 else { unlink(file.path); throw EmulatorDirectError("No room for the emulator's pictures.") }
        guard let mapped = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), mapped != MAP_FAILED else {
            unlink(file.path); throw EmulatorDirectError("The emulator's picture file could not be mapped.")
        }
        guard let buffer = device.makeBuffer(bytesNoCopy: mapped, length: length, options: .storageModeShared, deallocator: nil) else {
            munmap(mapped, length); unlink(file.path); throw EmulatorDirectError("The GPU could not read the emulator's pictures.")
        }
        self.file = file
        mapping = mapped
        mappedLength = length
        self.device = device
        self.queue = queue
        self.buffer = buffer
        self.pipeline = pipeline
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard resize(width: width, height: height) else {
            throw EmulatorDirectError("The emulator's screen width does not suit the GPU.")
        }
    }

    deinit {
        munmap(mapping, mappedLength)
        unlink(file.path)
    }

    /// Where the picture files live (this user's temporary folder).
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("terminaldeck-emulator-frames", isDirectory: true)
    }

    /// Picture files (about 10 MB each) whose app ended without removing them (a crash): removed when a
    /// panel opens. A file whose maker is still running (this app, or another copy of it) is never touched.
    static func sweep(in folder: URL = EmulatorFrames.folder, now: Date = Date()) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names {
            let path = folder.appendingPathComponent(name).path
            let made = (try? FileManager.default.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? now
            let unused = EmulatorFrameFiles.unused(fileName: name, age: now.timeIntervalSince(made)) { pid in
                kill(pid, 0) == 0 || errno == EPERM
            }
            if unused { unlink(path) }
        }
    }

    /// The raw pixels as the emulator wrote them (RGBA, rows as it sends them).
    func bytes(_ body: (UnsafeRawBufferPointer) -> Void) {
        body(UnsafeRawBufferPointer(start: mapping, count: min(mappedLength, width * height * 4)))
    }

    /// New picture dimensions (the screen turned): the same bytes, read with the new row length.
    /// False when the picture would not fit the file or the GPU cannot read rows of that length.
    func resize(width: Int, height: Int) -> Bool {
        lock.withLock {
            guard width > 0, height > 0, width * height * 4 <= mappedLength else { return false }
            let row = width * 4
            guard row % device.minimumLinearTextureAlignment(for: .rgba8Unorm) == 0 else { return false }
            let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
            description.usage = .shaderRead
            description.storageMode = .shared
            guard let source = buffer.makeTexture(descriptor: description, offset: 0, bytesPerRow: row) else { return false }
            var made: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true]
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made) == kCVReturnSuccess,
                  let made, let cache else { return false }
            var texture: CVMetalTexture?
            let usage = [kCVMetalTextureUsage: MTLTextureUsage([.shaderWrite, .shaderRead]).rawValue] as CFDictionary
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, made, usage, .bgra8Unorm, width, height, 0, &texture) == kCVReturnSuccess,
                  let texture else { return false }
            self.width = width
            self.height = height
            self.source = source
            target = made
            targetTexture = texture
            return true
        }
    }

    /// The screen surface the panel shows (replaced when the size changes).
    var surface: IOSurfaceRef? { lock.withLock { target.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() } } }

    /// A new picture is in the file: draw it into the surface. One at a time; pictures that arrive
    /// meanwhile are folded into one more pass. `done` runs on the GPU's thread.
    func draw(done: @escaping @Sendable () -> Void) {
        let start: Bool = lock.withLock {
            if busy { again = true; return false }
            busy = true
            return true
        }
        guard start else { return }
        encode(done: done)
    }

    private func encode(done: @escaping @Sendable () -> Void) {
        let job: (any MTLTexture, any MTLTexture, UInt32)? = lock.withLock {
            guard let source, let targetTexture, let target = CVMetalTextureGetTexture(targetTexture) else { return nil }
            return (source, target, rowsBottomUp ? 1 : 0)
        }
        guard let (source, target, flip) = job, let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else {
            lock.withLock { busy = false; again = false }
            return
        }
        var flag = flip
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&flag, length: MemoryLayout<UInt32>.size, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: target.width, height: target.height, depth: 1), threadsPerThreadgroup: group)
        encoder.endEncoding()
        // Held until the GPU is done with the mapped file: it is only unmapped after this.
        commands.addCompletedHandler { _ in
            done()
            let more: Bool = self.lock.withLock {
                if self.again { self.again = false; return true }
                self.busy = false
                return false
            }
            if more { self.encode(done: done) }
        }
        commands.commit()
    }
}

/// An Android emulator's direct path: its gRPC control port (Android Studio's way in), pictures by
/// shared memory, fingers and keys on one ordered input stream.
@MainActor final class EmulatorDirectSource: DeviceDirectSource {
    var onSurface: ((IOSurfaceRef) -> Void)?
    var onFrame: (() -> Void)?
    var onEnded: ((String) -> Void)?
    var inputReady: Bool { inputStream != nil && !stopped }
    /// Fingers only while the screen is upright and its size is known; a turned screen's touches go the engine's way.
    var canTouch: Bool { inputReady && rotation == 0 && size.width > 0 }
    var canType: Bool { inputReady }

    private let serial: String
    /// Where the emulators' discovery files are; nil is the real place (tests point elsewhere).
    private let discoveryFolder: URL?
    private var grpc: EmulatorGRPC?
    private var frames: EmulatorFrames?
    private var screenStream: UInt32?
    private var inputStream: UInt32?
    private var size = (width: 0, height: 0)
    private var rotation = 0
    private var shownSurface = false
    private var stopped = false
    private var paused = false
    private var calibration: Data?   // the PNG's pixels, until the first raw picture decides which way up rows run
    private var watchdog: Task<Void, Never>?

    init(serial: String, discoveryFolder: URL? = nil) {
        self.serial = serial
        self.discoveryFolder = discoveryFolder
    }

    /// The running emulator's discovery file for this serial (a live process only).
    nonisolated static func discovery(serial: String, folder: URL? = nil) -> EmulatorDiscovery? {
        guard let console = EmulatorDiscovery.consolePort(serial: serial) else { return nil }
        let running = folder ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/TemporaryItems/avd/running", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: running.path)) ?? []
        for name in names {
            guard let pid = EmulatorDiscovery.pid(fileName: name), kill(pid, 0) == 0,
                  let text = try? String(contentsOf: running.appendingPathComponent(name), encoding: .utf8),
                  let found = EmulatorDiscovery(ini: text), found.consolePort == console else { continue }
            return found
        }
        return nil
    }

    func start() {
        guard grpc == nil, !stopped else { return }
        let serial = self.serial, folder = discoveryFolder
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !Task.isCancelled, !self.stopped, !self.shownSurface else { return }
            self.end("The emulator did not show its screen in time.")
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            EmulatorFrames.sweep()
            guard let found = Self.discovery(serial: serial, folder: folder) else {
                await self?.end("This emulator has no control port to use (no gRPC discovery file).")
                return
            }
            do {
                let connection = try EmulatorGRPC.connect(port: found.grpcPort, token: found.token) { [weak self] reason in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.end(reason) } }
                }
                await self?.connected(connection)
            } catch {
                await self?.end(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        watchdog?.cancel()
        watchdog = nil
        let connection = grpc
        grpc = nil
        screenStream = nil
        inputStream = nil
        DispatchQueue.global(qos: .utility).async { connection?.close("Closed.") }
        frames = nil
    }

    func setPaused(_ now: Bool) {
        guard now != paused, !stopped else { return }
        paused = now
        if now, let stream = screenStream {
            screenStream = nil
            grpc?.cancel(stream: stream)
        } else if !now, frames != nil {
            openScreenStream()
        }
    }

    func send(_ input: DeviceInput) -> Bool {
        guard inputReady else { return false }
        switch input {
        case let .touch(phase, x, y):
            guard canTouch else { return false }
            let at = EmulatorWire.pixel(x: x, y: y, width: size.width, height: size.height)
            return post(EmulatorWire.touchEvent([.init(x: at.x, y: at.y, id: 0, down: phase != "up")]))
        case let .tap(x, y, hold):
            guard canTouch else { return false }
            play(DeviceDirectGesture.tap(x: x, y: y, holdMs: hold))
            return true
        case let .swipe(fromX, fromY, toX, toY, ms):
            guard canTouch else { return false }
            play(DeviceDirectGesture.swipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY, ms: ms))
            return true
        case .type(let text):
            guard EmulatorWire.typeable(text), text.count <= 256 else { return false }
            return post(EmulatorWire.typeEvent(text))
        case .key(let name):
            guard let key = EmulatorWire.keyName(name) else { return false }
            return post(EmulatorWire.keyEvent(key))
        case .button(let name):
            guard let key = EmulatorWire.buttonName(name) else { return false }
            return post(EmulatorWire.keyEvent(key))
        }
    }

    func pinch(phase: String, first: CGPoint, second: CGPoint) -> Bool {
        guard canTouch else { return false }
        let a = EmulatorWire.pixel(x: first.x, y: first.y, width: size.width, height: size.height)
        let b = EmulatorWire.pixel(x: second.x, y: second.y, width: size.width, height: size.height)
        let down = phase != "up"
        return post(EmulatorWire.touchEvent([.init(x: a.x, y: a.y, id: 0, down: down), .init(x: b.x, y: b.y, id: 1, down: down)]))
    }

    // MARK: Inside

    private func play(_ steps: [DeviceDirectTouchStep]) {
        for step in steps {
            let at = EmulatorWire.pixel(x: step.x, y: step.y, width: size.width, height: size.height)
            let event = EmulatorWire.touchEvent([.init(x: at.x, y: at.y, id: 0, down: !step.up)])
            if step.atMs <= 0 { post(event); continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + step.atMs / 1000) { MainActor.assumeIsolated { _ = self.post(event) } }
        }
    }

    /// Queues one input event (the connection writes it on its own queue; the main thread never waits on
    /// the socket). A write that fails there ends the connection, and the panel goes back to the video.
    @discardableResult private func post(_ event: Data) -> Bool {
        guard let grpc, let stream = inputStream, !stopped else { return false }
        if grpc.send(stream: stream, message: event) { return true }
        // Not queued (the stream ended, or the emulator is hopelessly behind): input goes the engine's way from now on.
        inputStream = nil
        return false
    }

    private func connected(_ connection: EmulatorGRPC) {
        guard !stopped else { DispatchQueue.global(qos: .utility).async { connection.close("Closed.") }; return }
        grpc = connection
        // One PNG of the screen: its real size, and which way up the raw pictures' rows run. Decoding it and
        // setting up the GPU step take a moment, so both happen off the main thread (the app never pauses).
        //
        // A gRPC unary reply always ends by closing the call (END_STREAM on its trailing headers), so `onEnd`
        // fires on every call — even a successful one where the screenshot arrived first. `onMessage` then
        // prepares the picture off the main thread (reading thread → global queue → main), while `onEnd` reaches
        // the main thread in one hop; the end therefore won the race and killed the direct path on EVERY call,
        // before `frames` was ever set, dropping the panel to the slower engine video (Asad 23 Oct: the ~20 s
        // typing lag). `arrived` is set the instant the bytes land on the reading thread — before `onEnd` runs
        // on that same thread — so a delivered screenshot is never mistaken for an empty call.
        let arrived = GotFirstScreenshot()
        connection.call("getScreenshot", message: EmulatorWire.imageFormat(rgba: false, width: 0, height: 0, mmapURL: nil), last: true,
            onMessage: { [weak self] data in
                arrived.set()
                let image = EmulatorWire.image(data)
                DispatchQueue.global(qos: .userInitiated).async {
                    let prepared = Self.prepare(image)
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.firstPicture(prepared) } }
                }
            }, onEnd: { [weak self] reason in
                // A screenshot did arrive: its own off-thread preparation reports any real failure (a GPU
                // problem, a screen that is off) and the watchdog covers a reply that never draws. Only an
                // empty call — a refused token, an old emulator — is a failure to report here.
                guard !arrived.isSet else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, !self.stopped, self.frames == nil else { return }
                    self.end("The emulator gave no screen picture: \(reason)")
                } }
            })
        // Input: one stream for every finger and key, so they arrive in the order they were made.
        inputStream = connection.call("streamInputEvent", message: nil, last: false, onMessage: { _ in },
            onEnd: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    NativeCompositionRoot.note("device direct: emulator input stream ended: \(reason)")
                    self?.inputStream = nil
                } }
            })
    }

    /// The first picture, made ready off the main thread: the PNG as pixels, and the picture file and GPU step.
    private struct FirstPicture: @unchecked Sendable {
        let image: EmulatorWire.Image
        let calibration: Data?
        let frames: Result<EmulatorFrames, EmulatorDirectError>
    }

    nonisolated private static func prepare(_ image: EmulatorWire.Image) -> FirstPicture {
        guard image.width > 0, image.height > 0 else {
            return FirstPicture(image: image, calibration: nil, frames: .failure(EmulatorDirectError("The emulator's screen is off.")))
        }
        let calibration = rgba(png: image.bytes, width: image.width, height: image.height)
        do {
            return FirstPicture(image: image, calibration: calibration, frames: .success(try EmulatorFrames(width: image.width, height: image.height)))
        } catch {
            return FirstPicture(image: image, calibration: nil, frames: .failure(EmulatorDirectError(error.localizedDescription)))
        }
    }

    private func firstPicture(_ prepared: FirstPicture) {
        guard !stopped, frames == nil else { return }   // a file made meanwhile goes with `prepared`
        let image = prepared.image
        switch prepared.frames {
        case .success(let made): frames = made
        case .failure(let problem): end(problem.message); return
        }
        calibration = prepared.calibration
        size = (image.width, image.height)
        rotation = image.rotation
        if !paused { openScreenStream() }
    }

    private func openScreenStream() {
        guard let grpc, let frames, screenStream == nil, !stopped else { return }
        let format = EmulatorWire.imageFormat(rgba: true, width: frames.width, height: frames.height, mmapURL: frames.file.absoluteString)
        screenStream = grpc.call("streamScreenshot", message: format, last: true,
            onMessage: { [weak self] data in
                let image = EmulatorWire.image(data)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.picture(image) } }
            },
            onEnd: { [weak self] reason in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, !self.stopped, !self.paused else { return }
                    self.end("The emulator's screen stream ended: \(reason)")
                } }
            })
        if screenStream == nil { end("The emulator would not stream its screen.") }
    }

    /// The emulator wrote a new picture into the file.
    private func picture(_ image: EmulatorWire.Image) {
        guard !stopped, let frames, image.width > 0, image.height > 0 else { return }
        if image.width != frames.width || image.height != frames.height {
            guard frames.resize(width: image.width, height: image.height) else { end("The emulator's screen changed size."); return }
            shownSurface = false
        }
        size = (image.width, image.height)
        rotation = image.rotation
        if let calibration {
            self.calibration = nil
            frames.bytes { raw in frames.flipped = EmulatorWire.bottomUp(raw: raw, png: calibration, width: image.width, height: image.height) }
        }
        frames.draw { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.drawn() } }
        }
    }

    private func drawn() {
        guard !stopped, let frames else { return }
        if !shownSurface, let surface = frames.surface {
            shownSurface = true
            watchdog?.cancel()
            onSurface?(surface)
        } else {
            onFrame?()
        }
    }

    private func end(_ reason: String) {
        guard !stopped else { return }
        NativeCompositionRoot.note("device direct: \(serial): \(reason)")
        stop()
        onEnded?(reason)
    }

    /// The PNG as RGBA bytes, top row first, at the given size.
    nonisolated static func rgba(png: Data, width: Int, height: Int) -> Data? {
        guard !png.isEmpty, let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var bytes = Data(count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }
}
