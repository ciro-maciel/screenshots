import AppKit
import AVFoundation
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

/// Screen recording: ScreenCaptureKit frames written by AVAssetWriter into an MP4 (H.264,
/// AAC). A GIF is made from the finished MP4.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Options {
        var fps = 30
        var cursor = true
        var systemAudio = false
        var microphone = false
        var retina = true
    }

    private let queue = DispatchQueue(label: "click.ciromaciel.screenshots.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var started = false
    private(set) var frames = 0
    /// Frames ScreenCaptureKit delivered, by status (complete, idle, blank…), for diagnosis.
    private(set) var statuses: [Int: Int] = [:]
    let url: URL

    init(url: URL) { self.url = url }

    @MainActor
    func start(rect: CGRect, options: Options) async throws {
        Recorder.trace("recorder start")
        guard let screen = Geometry.screen(for: rect) else { throw CaptureError.noDisplay }
        let clipped = rect.intersection(screen.frame).integral
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        Recorder.trace("shareable content")
        let id = Geometry.displayID(screen)
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
        let excluded = CaptureExclusion.windowNumbers
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excluded.contains(Int($0.windowID)) })

        var scale = options.retina ? screen.backingScaleFactor : 1
        // At most 4K on the long side: a whole 5K screen in Retina is past what the hardware
        // encoder takes, and each frame in flight would cost three times as much.
        scale = min(scale, 3840 / max(clipped.width, clipped.height))
        // H.264 wants even sides.
        let w = Int(clipped.width * scale) / 2 * 2, h = Int(clipped.height * scale) / 2 * 2
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: clipped.minX - screen.frame.minX, y: screen.frame.maxY - clipped.maxY,
                                   width: clipped.width, height: clipped.height)
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
        config.showsCursor = options.cursor
        // Memory while recording is these frames in flight: four of them, in the encoder's own
        // format (4:2:0, 1.5 bytes a pixel instead of 4), whatever the length of the recording.
        config.queueDepth = 4
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if #available(macOS 15.0, *), options.microphone { config.captureMicrophone = true }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        Recorder.trace("writer created")
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, w * h * options.fps / 8),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                // No B-frames: the encoder hands each screen frame back at once, so the capture
                // never runs out of frames while it waits for a reordering window.
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                            AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 160_000]
        if options.systemAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            audioInput = a
        }
        if #available(macOS 15.0, *), options.microphone {
            let m = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            m.expectsMediaDataInRealTime = true
            writer.add(m)
            micInput = m
        }
        // Fragments every 10 s: the index is written as it goes instead of growing in memory for
        // the whole recording, and a crash still leaves a playable file.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
        writer.startWriting()
        Recorder.trace("writer started")
        self.writer = writer
        videoInput = video

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        if #available(macOS 15.0, *), options.microphone { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
        Recorder.trace("stream configured")
        try await stream.startCapture()
        Recorder.trace("capture started")
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer, sb.isValid else { return }
        switch type {
        case .screen:
            // Only complete frames carry pixels; idle and blank ones are skipped.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int else { return }
            statuses[raw, default: 0] += 1
            guard SCFrameStatus(rawValue: raw) == .complete else { return }
            if !started {
                writer.startSession(atSourceTime: sb.presentationTimeStamp)
                started = true
            }
            if videoInput?.isReadyForMoreMediaData == true {
                if videoInput?.append(sb) == true { frames += 1 }
                else if frames < 3 { Recorder.trace("append failed: \(writer.status.rawValue) \(writer.error?.localizedDescription ?? "")") }
            }
            if frames == 30 { Recorder.trace("30 frames written") }
        case .audio:
            if started, audioInput?.isReadyForMoreMediaData == true { audioInput?.append(sb) }
        default:
            if started, micInput?.isReadyForMoreMediaData == true { micInput?.append(sb) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}

    /// SCREENSHOTS_TRACE_MEMORY=1: the app's memory at each step of starting a recording.
    static func trace(_ step: String) {
        guard ProcessInfo.processInfo.environment["SCREENSHOTS_TRACE_MEMORY"] == "1" else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        print(String(format: "        trace %-20@ %.1f MB", step as NSString, Double(info.phys_footprint) / 1_048_576)); fflush(stdout)
    }

    /// Stops and closes the file. Returns false when no frame was written.
    func stop() async -> Bool {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        return await withCheckedContinuation { cont in
            queue.async {
                guard let writer = self.writer, self.started else {
                    self.writer?.cancelWriting()
                    cont.resume(returning: false)
                    return
                }
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
                self.micInput?.markAsFinished()
                writer.finishWriting { cont.resume(returning: writer.status == .completed) }
            }
        }
    }

    func cancel() async {
        _ = await stop()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: GIF

    /// The MP4 as an animated GIF: 15 frames a second, at most 960 pixels wide, looping.
    /// ImageIO keeps every GIF frame in memory until the end, so a long recording gets fewer
    /// frames a second: never more than `maxFrames`, whatever the length.
    static func makeGIF(from video: URL, to gif: URL, fps wanted: Double = 15, maxWidth: CGFloat = 960, maxFrames: Int = 450) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        let fps = min(wanted, Double(maxFrames) / max(duration, 0.1))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.maximumSize = CGSize(width: maxWidth, height: maxWidth * 4)
        let count = max(1, Int(duration * fps))
        try? FileManager.default.removeItem(at: gif)
        guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw CaptureError.empty
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps,
                                                          kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let (img, _) = try? await gen.image(at: t) {
                CGImageDestinationAddImage(dest, img, frameProps)
            }
        }
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.empty }
    }
}

// MARK: - The recording on screen: frame, control bar, clicks

@MainActor
@Observable
final class RecordingSession {
    static private(set) var current: RecordingSession?

    let rect: CGRect
    let gif: Bool
    private(set) var startedAt: Date?
    private(set) var countdown = 0
    private let recorder: Recorder
    private var frameWindow: NSWindow?
    private var bar: NSPanel?
    private var clickMonitor: Any?
    private var continuation: CheckedContinuation<URL?, Never>?
    private var cancelled = false

    init(rect: CGRect, gif: Bool) {
        self.rect = rect
        self.gif = gif
        recorder = Recorder(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("screenshot-\(UUID().uuidString).mp4"))
    }

    var frames: Int { recorder.frames }
    var statuses: [Int: Int] { recorder.statuses }

    /// Countdown, record until Stop, then the finished file (MP4 or GIF); nil when cancelled.
    func run(countdown seconds: Int = 3) async -> URL? {
        RecordingSession.current = self
        Recorder.trace("session start")
        showChrome()
        Recorder.trace("chrome shown")
        for s in stride(from: seconds, to: 0, by: -1) {
            countdown = s
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if cancelled { return finishChrome(nil) }
        }
        countdown = 0
        let p = Prefs.shared
        do {
            try await recorder.start(rect: rect, options: .init(fps: p.recordFPS, cursor: p.recordCursor,
                                                                systemAudio: p.recordSystemAudio,
                                                                microphone: p.recordMicrophone, retina: p.recordRetina))
        } catch {
            HUD.shared.toast(error.localizedDescription, error: true)
            return finishChrome(nil)
        }
        startedAt = Date()
        // Under the isolated tests the person's own clicks must not draw rings.
        if p.recordClicks, !Stage.isolated { watchClicks() }
        StatusMenu.shared.recording(true)
        return await withCheckedContinuation { cont in continuation = cont }
    }

    func stop() {
        guard let cont = continuation else { return }
        continuation = nil
        Task {
            let ok = await recorder.stop()
            var out: URL? = ok ? recorder.url : nil
            if ok, gif {
                let g = recorder.url.deletingPathExtension().appendingPathExtension("gif")
                HUD.shared.toast(L("Building the GIF…"))
                do {
                    try await Recorder.makeGIF(from: recorder.url, to: g)
                    try? FileManager.default.removeItem(at: recorder.url)
                    out = g
                } catch {
                    HUD.shared.toast(L("Couldn't build the GIF."), error: true)
                    out = nil
                }
            }
            cont.resume(returning: finishChrome(out))
        }
    }

    func cancel() {
        cancelled = true
        guard let cont = continuation else { return }
        continuation = nil
        Task {
            await recorder.cancel()
            cont.resume(returning: finishChrome(nil))
        }
    }

    @discardableResult
    private func finishChrome(_ url: URL?) -> URL? {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        for w in [frameWindow, bar].compactMap({ $0 }) { w.dispose() }
        DispatchQueue.main.async { Memory.trim() }
        frameWindow = nil; bar = nil
        StatusMenu.shared.recording(false)
        if RecordingSession.current === self { RecordingSession.current = nil }
        return url
    }

    private func showChrome() {
        let outer = rect.insetBy(dx: -3, dy: -3)
        let fw = NSWindow(contentRect: outer, styleMask: .borderless, backing: .buffered, defer: false)
        fw.isOpaque = false
        fw.backgroundColor = .clear
        fw.ignoresMouseEvents = true
        fw.level = .statusBar
        fw.hasShadow = false
        fw.isReleasedWhenClosed = false
        fw.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let isFull = Geometry.screen(for: rect).map { rect.size == $0.frame.size } ?? false
        fw.contentView = isFull ? NSView() : FrameBorderView(frame: CGRect(origin: .zero, size: outer.size))
        CaptureExclusion.add(fw)
        fw.orderFrontRegardless()
        frameWindow = fw

        let host = NSHostingView(rootView: RecordingBar(session: self))
        let size = host.fittingSize
        let visible = Geometry.screen(for: rect)?.visibleFrame ?? rect
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 12)
        if origin.y < visible.minY + 8 { origin.y = max(rect.minY, visible.minY) + 16 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.contentView = host
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        CaptureExclusion.add(p)
        p.orderFrontRegardless()
        bar = p
    }

    /// A ring where the mouse clicks, drawn in a window that is recorded.
    private func watchClicks() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            MainActor.assumeIsolated { ClickRing.show(at: NSEvent.mouseLocation) }
        }
    }
}

@MainActor
enum ClickRing {
    static func show(at p: CGPoint) {
        let side: CGFloat = 44
        let w = NSWindow(contentRect: CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .screenSaver
        w.hasShadow = false
        w.isReleasedWhenClosed = false
        let v = NSView(frame: CGRect(x: 0, y: 0, width: side, height: side))
        v.wantsLayer = true
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: side - 8, height: side - 8), transform: nil)
        ring.fillColor = NSColor(hex: 0x11181C, alpha: 0.18).cgColor
        ring.strokeColor = NSColor(hex: 0x11181C, alpha: 0.85).cgColor
        ring.lineWidth = 2
        v.layer?.addSublayer(ring)
        w.contentView = v
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            w.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { w.dispose() } })
    }
}

struct RecordingBar: View {
    let session: RecordingSession
    var body: some View {
        HStack(spacing: 12) {
            GripHandle()
            if session.countdown > 0 {
                Text(L("Starts in %d", session.countdown)).font(Zen.font(13, .black)).foregroundStyle(Zen.gray9).monospacedDigit()
                    .frame(width: 112, alignment: .leading)
            } else {
                Circle().fill(Zen.red7).frame(width: 8, height: 8)
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    Text(Self.clock(session.startedAt.map { ctx.date.timeIntervalSince($0) } ?? 0))
                        .font(Zen.font(13, .black)).foregroundStyle(Zen.gray9).monospacedDigit()
                }
                .frame(width: 92, alignment: .leading)
            }
            Text(session.gif ? "GIF" : L("Video")).zenLabel(9, color: Zen.gray5)
            Button { session.cancel() } label: { ButtonLabel(title: L("Cancel"), icon: "x") }
                .buttonStyle(ZenButtonStyle(kind: .subtle, height: 30))
            Button { session.stop() } label: { ButtonLabel(title: L("Stop"), icon: "player-stop", color: .white) }
                .buttonStyle(ZenButtonStyle(kind: .primary, height: 30))
                .disabled(session.countdown > 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(WindowDragArea())
        .background(Zen.gray0)
        .overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
