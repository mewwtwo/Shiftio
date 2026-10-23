import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers

enum WatermarkMode: String, CaseIterable, Identifiable {
    case off, text, image
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .text: String(localized: "Text")
        case .image: String(localized: "Image")
        }
    }
}

/// Settings for a place people send video to.
enum VideoPreset: String, CaseIterable, Identifiable {
    case whatsApp, telegram, reels, discord, web
    var id: String { rawValue }

    var title: String {
        switch self {
        case .whatsApp: "WhatsApp"
        case .telegram: "Telegram"
        case .reels: "Instagram Reels"
        case .discord: "Discord"
        case .web: String(localized: "Web, small")
        }
    }

    var detail: String {
        switch self {
        case .whatsApp: String(localized: "MP4 · 720p · up to 16 MB")
        case .telegram: String(localized: "MP4 · 1080p")
        case .reels: String(localized: "MP4 · 9:16 · 1080p")
        case .discord: String(localized: "MP4 · 720p · up to 10 MB")
        case .web: String(localized: "MP4 · 720p · no metadata")
        }
    }
}

enum VideoEditMode: String, CaseIterable, Identifiable {
    case trim, cut
    var id: String { rawValue }
    var title: String { self == .trim ? String(localized: "Trim") : String(localized: "Cut Out") }
}

/// The four draggable ends on the timeline: the kept range, and the piece about to be cut out of it.
enum VideoHandle { case trimStart, trimEnd, cutStart, cutEnd }

@MainActor @Observable
final class VideoEditModel {
    /// Shortest clip the trim handles allow.
    static let minimumLength = 0.5
    static let thumbnailCount = 9

    let url: URL
    let player = AVPlayer()
    private let asset: AVURLAsset
    private var track: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    /// Seeks are sent one at a time, newest last, so dragging never queues up a backlog.
    private var pendingSeek: (time: Double, precise: Bool)?
    private var isSeeking = false
    private var layoutGeneration = 0
    @ObservationIgnored private nonisolated(unsafe) var observer: Any?

    private(set) var duration = 0.0
    private(set) var frameRate = 30.0
    var start = 0.0
    var end = 0.0
    private(set) var current = 0.0
    private(set) var isPlaying = false
    private(set) var isLoaded = false
    private(set) var hasAudio = false
    private(set) var thumbnails: [CGImage?] = []
    private(set) var quarterTurns = 0
    private(set) var flipped = false
    var crop = VideoCrop.original { didSet { Task { await applyLayout() } } }
    var speed = 1.0 {
        didSet {
            player.defaultRate = Float(speed)
            if isPlaying { player.rate = Float(speed) }
        }
    }
    var mode = VideoEditMode.trim
    /// The piece the Cut Out tool is about to remove.
    private(set) var cutStart = 0.0
    private(set) var cutEnd = 0.0
    /// Pieces already cut out, sorted and not overlapping.
    private(set) var cuts: [Range<Double>] = []
    var volume = 1.0 { didSet { applyAudio() } }
    /// Sound to work with: the clip's own, or a file chosen to replace it.
    var hasSound: Bool { hasAudio || replacementSound != nil }

    /// Shape of the saved picture, as width over height.
    var outputAspect: CGFloat {
        if let aspect = crop.aspect { return aspect }
        let size = quarterTurns % 2 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
        return size.height > 0 ? size.width / size.height : 16.0 / 9.0
    }

    var canSave: Bool { isLoaded && hasChanges && !isSaving && !isProcessingSound && !isTranscribing }
    var fadeIn = 0.0
    var fadeOut = 0.0
    var output = SaveFormat.mp4
    var resolution = VideoResolution.original
    var mp3Bitrate = 192
    var gif = GIFOptions()
    var stripsMetadata = false
    private(set) var sourceSize = CGSize(width: 16, height: 9)
    var reversed = false
    /// Where the clip is split; saving then writes one file per part.
    private(set) var splits: [Double] = []
    private(set) var blurs: [VideoBlur] = []
    var selectedBlur: UUID?
    var watermarkMode = WatermarkMode.off { didSet { updateWatermarkImage() } }
    var watermarkText = "" { didSet { updateWatermarkImage() } }
    private(set) var watermarkFile: URL? { didSet { updateWatermarkImage() } }
    var watermarkSize = WatermarkSize.medium
    var watermarkOpacity = 0.85
    var watermarkCorner = WatermarkCorner.bottomRight {
        didSet {
            // A mark repeated over the whole picture reads better lighter.
            if watermarkCorner == .tiled, oldValue != .tiled, watermarkOpacity == Self.defaultOpacity { watermarkOpacity = 0.35 }
            if watermarkCorner != .tiled, oldValue == .tiled, watermarkOpacity == 0.35 { watermarkOpacity = Self.defaultOpacity }
        }
    }
    static let defaultOpacity = 0.85
    private(set) var watermarkImage: CGImage?
    var subtitleMode = SubtitleMode.off {
        didSet { if subtitleMode != .off, transcript == nil { Task { await transcribe() } } }
    }
    private var transcript: [Transcriber.Segment]?
    private(set) var isTranscribing = false
    var normalizes = false { didSet { if normalizes != oldValue { Task { await refreshLoudness() } } } }
    private(set) var normalizeGain = 1.0 { didSet { applyAudio() } }
    var reducesNoise = false { didSet { if reducesNoise != oldValue { Task { await refreshNoise() } } } }
    private(set) var isProcessingSound = false
    private var cleanedSound: URL?
    private var soundGeneration = 0
    private(set) var replacementSound: URL?
    /// Megabytes the saved video should stay under.
    var sizeLimitMB: Int?
    /// Whole clips added after this one, in order.
    private(set) var joined: [URL] = []
    private(set) var isFindingSilence = false
    /// Size of the saved file as the encoder expects it; nil while unknown or not applicable (GIF).
    private(set) var estimatedSize: Int64?
    var isSaving = false
    var message: String?
    var isMuted = false { didSet { player.isMuted = isMuted } }

    init(url: URL) {
        self.url = url
        asset = AVURLAsset(url: url)
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }

    /// The parts that stay: the trimmed range minus the cuts.
    var keptRanges: [Range<Double>] {
        var kept: [Range<Double>] = []
        var position = start
        for cut in cuts where cut.upperBound > start && cut.lowerBound < end {
            let lower = max(cut.lowerBound, start), upper = min(cut.upperBound, end)
            if lower > position { kept.append(position..<lower) }
            position = max(position, upper)
        }
        if end > position { kept.append(position..<end) }
        return kept
    }

    /// Length of the saved clip, cuts and speed included, plus the clips joined after it.
    var length: Double { keptRanges.reduce(0) { $0 + $1.upperBound - $1.lowerBound } / speed + joinedLength }

    private(set) var joinedLength = 0.0

    /// Changes whenever the saved file would come out a different size.
    var sizeKey: String {
        var parts: [String] = keptRanges.map { "\($0.lowerBound)-\($0.upperBound)" }
        parts += ["\(speed)", "\(quarterTurns)", crop.rawValue, resolution.rawValue, output.rawValue, "\(mp3Bitrate)", "\(isMuted)"]
        parts += ["\(volume)", "\(fadeIn)", "\(fadeOut)", "\(isLoaded)", "\(reversed)", "\(normalizeGain)", "\(normalizes)"]
        parts += joined.map(\.path) + [cleanedSound?.path ?? "", replacementSound?.path ?? "", "\(sizeLimitMB ?? 0)"]
        return parts.joined(separator: "|")
    }

    private var edit: VideoEdit { makeEdit(ranges: keptRanges) }

    /// The edit for `ranges` of the source (all that is kept, or one part of it).
    private func makeEdit(ranges: [Range<Double>]) -> VideoEdit {
        var made = VideoEdit(segments: ranges.map {
                      CMTimeRange(start: CMTime(seconds: $0.lowerBound, preferredTimescale: 600),
                                  end: CMTime(seconds: $0.upperBound, preferredTimescale: 600))
                  },
                  muted: isMuted, quarterTurns: quarterTurns, flipped: flipped, crop: crop, speed: speed,
                  volume: volume, fadeIn: fadeIn, fadeOut: fadeOut, output: output, resolution: resolution,
                  mp3Bitrate: mp3Bitrate, gif: gif, joined: joined, stripsMetadata: stripsMetadata)
        made.reversed = reversed && output.group != .audio
        made.blurs = blurs
        made.watermark = watermarkImage.map { Watermark(image: $0, corner: watermarkCorner, size: watermarkSize, opacity: watermarkOpacity) }
        made.subtitles = subtitleMode == .burnIn ? cues(for: ranges) : []
        made.alignedAudio = cleanedSound
        made.replacementAudio = replacementSound
        made.normalizeGain = normalizes ? normalizeGain : 1
        made.sizeLimit = sizeLimitMB.map { Int64($0) * 1_000_000 }
        return made
    }

    /// What the preview shows: the picture and the level, but not fades or a smaller size. Those belong to the end of the saved clip,
    /// not to the start and end of the source.
    private var previewEdit: VideoEdit {
        var copy = edit
        copy.fadeIn = 0
        copy.fadeOut = 0
        copy.resolution = .original
        copy.joined = []
        copy.reversed = false
        copy.blurs = []
        copy.watermark = nil
        copy.subtitles = []
        copy.alignedAudio = nil
        copy.replacementAudio = nil
        return copy
    }

    var hasChanges: Bool {
        start > 0.01 || end < duration - 0.01 || !cuts.isEmpty || (isMuted && hasAudio) || speed != 1 || edit.changesPicture
            || (hasAudio && edit.changesSound) || output != .mp4 || !joined.isEmpty || stripsMetadata
            || reversed || !blurs.isEmpty || watermarkImage != nil || (subtitleMode != .off && transcript != nil) || normalizes
            || reducesNoise || replacementSound != nil || sizeLimitMB != nil || !splits.isEmpty
    }

    func load() async {
        do {
            let length = try await asset.load(.duration).seconds
            guard let video = try await asset.loadTracks(withMediaType: .video).first, length > 0
            else { throw ShiftioError.unreadable(url) }
            track = video
            let (natural, transform) = try await video.load(.naturalSize, .preferredTransform)
            sourceSize = CGRect(origin: .zero, size: natural).applying(transform).size
            let rate = try await video.load(.nominalFrameRate)
            if rate > 0 { frameRate = Double(rate) }
            audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            hasAudio = audioTrack != nil
            duration = length
            end = length
            cutStart = length * 0.4
            cutEnd = length * 0.6
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated { self?.tick(time.seconds) }
            }
            isLoaded = true
            await loadThumbnails(layout: nil, generation: layoutGeneration)
        } catch {
            message = error.localizedDescription
        }
    }

    /// The strip shows the picture as it will be saved (turned, flipped, cropped). A newer layout cancels an older run.
    private func loadThumbnails(layout: AVVideoComposition?, generation: Int) async {
        let count = Self.thumbnailCount
        if thumbnails.count != count { thumbnails = Array(repeating: nil, count: count) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.videoComposition = layout
        generator.maximumSize = CGSize(width: 240, height: 240)
        let times = (0..<count).map { CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        for await result in generator.images(for: times) {
            guard generation == layoutGeneration, let image = try? result.image,
                  let index = times.firstIndex(where: { CMTimeCompare($0, result.requestedTime) == 0 }) else { continue }
            thumbnails[index] = image
        }
    }

    // MARK: Playback

    private func tick(_ time: Double) {
        // While a seek is on its way the player still reports the old time; the playhead already shows the new one.
        guard !isSeeking, pendingSeek == nil else { return }
        current = time
        guard isPlaying else { return }
        if time >= end - 0.02 {
            pause()
            seek(to: start)
        } else if let cut = cuts.first(where: { $0.contains(time) }) {
            seek(to: cut.upperBound, precise: false)
        }
    }

    /// `precise: false` is for dragging: the nearest frame is good enough and keeps the picture following the pointer.
    func seek(to time: Double, precise: Bool = true) {
        let clamped = min(max(time, 0), duration)
        current = clamped
        pendingSeek = (clamped, precise)
        if !isSeeking { sendSeek() }
    }

    private func sendSeek() {
        guard let (time, precise) = pendingSeek else { return }
        pendingSeek = nil
        isSeeking = true
        // Dragging only needs a frame close by; either way it is a real frame, never a far-off keyframe.
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.5 / frameRate, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.sendSeek()
            }
        }
    }

    /// One frame (or, with `seconds`, that long) forwards or back, inside the kept range.
    func step(frames: Int = 0, seconds: Double = 0) {
        pause()
        let delta = Double(frames) / frameRate + seconds
        seek(to: min(max(current + delta, start), end))
    }

    func togglePlay() {
        if isPlaying { pause(); return }
        if current < start || current >= end - 0.05 { seek(to: start) }
        player.rate = Float(speed)
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    // MARK: Edits

    func time(of handle: VideoHandle) -> Double {
        switch handle {
        case .trimStart: start
        case .trimEnd: end
        case .cutStart: cutStart
        case .cutEnd: cutEnd
        }
    }

    /// Moves a handle, keeping the pair apart and inside what the trim keeps, and shows the frame under it.
    func set(_ handle: VideoHandle, to time: Double) {
        let gap = min(handle == .cutStart || handle == .cutEnd ? 0.1 : Self.minimumLength, duration)
        switch handle {
        case .trimStart: start = min(max(time, 0), end - gap)
        case .trimEnd: end = max(min(time, duration), start + gap)
        case .cutStart: cutStart = min(max(time, start), cutEnd - gap)
        case .cutEnd: cutEnd = max(min(time, end), cutStart + gap)
        }
        keepCutInsideTrim()
        pause()
        seek(to: self.time(of: handle), precise: false)
    }

    /// Trimming can leave the cut selection outside the range.
    private func keepCutInsideTrim() {
        cutStart = min(max(cutStart, start), max(start, end - 0.1))
        cutEnd = max(min(cutEnd, end), min(end, cutStart + 0.1))
    }

    /// The pair of handles of the current mode.
    func pair(of mode: VideoEditMode) -> (Double, Double) {
        mode == .trim ? (start, end) : (cutStart, cutEnd)
    }

    /// Slides both handles together, keeping the distance between them. The trim moves inside the clip, the
    /// piece to cut out moves inside the trim.
    func moveRange(_ mode: VideoEditMode, from base: (Double, Double), by delta: Double) {
        let length = base.1 - base.0
        let lower = mode == .trim ? 0 : start
        let upper = mode == .trim ? duration : end
        let newStart = min(max(base.0 + delta, lower), max(lower, upper - length))
        switch mode {
        case .trim:
            start = newStart
            end = newStart + length
            keepCutInsideTrim()
        case .cut:
            cutStart = newStart
            cutEnd = newStart + length
        }
        pause()
        seek(to: newStart, precise: false)
    }

    /// Removes the selected piece. Refuses when nothing would be left.
    func cutOut() {
        let piece = max(cutStart, start)..<min(cutEnd, end)
        guard piece.upperBound - piece.lowerBound > 0.05, add(cuts: [piece]) else { return }
        pause()
        seek(to: piece.upperBound)
        let span = piece.upperBound - piece.lowerBound
        cutStart = min(piece.upperBound, end - 0.1)
        cutEnd = min(end, cutStart + span)
    }

    /// Merges `pieces` into the cuts. Refuses, and says so, when nothing would be left.
    @discardableResult
    private func add(cuts pieces: [Range<Double>]) -> Bool {
        var merged: [Range<Double>] = []
        for cut in (cuts + pieces).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, cut.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, cut.upperBound)
            } else {
                merged.append(cut)
            }
        }
        let before = cuts
        cuts = merged
        guard keptRanges.reduce(0, { $0 + $1.upperBound - $1.lowerBound }) > 0.1 else {
            cuts = before
            message = String(localized: "Can't cut everything out")
            return false
        }
        message = nil
        return true
    }

    /// Cuts out every pause in the kept range. Cuts can be undone with Restore Cuts.
    func removeSilence() async {
        guard hasAudio, !isMuted, !isFindingSilence else { return }
        isFindingSilence = true
        defer { isFindingSilence = false }
        pause()
        let found = await VideoSilence.ranges(in: url, within: start..<end)
        guard !found.isEmpty else {
            message = String(localized: "No pauses found")
            return
        }
        guard add(cuts: found) else { return }
        message = String(localized: "Pauses cut out: \(found.count)")
        seek(to: start)
    }

    /// Asks for video files to put after this clip.
    func chooseClipsToJoin() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose videos to add after this clip")
        guard panel.runModal() == .OK else { return }
        var added: [URL] = []
        for file in panel.urls {
            let other = AVURLAsset(url: file)
            guard let length = try? await other.load(.duration).seconds, length > 0,
                  (try? await other.loadTracks(withMediaType: .video).first) != nil
            else {
                message = String(localized: "\(file.lastPathComponent) can't be read")
                continue
            }
            added.append(file)
            joinedLength += length
        }
        joined += added
    }

    func removeJoined() {
        joined = []
        joinedLength = 0
    }

    /// Asks the encoder how big the saved file will be. Cancelled and restarted by the view whenever the edit changes.
    func refreshEstimate() async {
        guard isLoaded else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let size = await VideoExporter.estimatedSize(url, edit: edit)
        guard !Task.isCancelled else { return }
        estimatedSize = size
    }

    // MARK: Split

    func split() {
        guard current > start + 0.2, current < end - 0.2 else {
            message = String(localized: "Move the playhead inside the clip to split")
            return
        }
        guard !splits.contains(where: { abs($0 - current) < 0.2 }) else { return }
        splits = (splits + [current]).sorted()
        message = String(localized: "\(splits.count + 1) parts, saved as separate files")
    }

    func clearSplits() {
        splits = []
        message = nil
    }

    // MARK: Blur

    func addBlur(pixelates: Bool) {
        let blur = VideoBlur(rect: CGRect(x: 0.3, y: 0.35, width: 0.4, height: 0.3), pixelates: pixelates)
        blurs.append(blur)
        selectedBlur = blur.id
    }

    func removeBlur() {
        guard let index = blurs.firstIndex(where: { $0.id == selectedBlur }) ?? blurs.indices.last else { return }
        blurs.remove(at: index)
        selectedBlur = blurs.last?.id
    }

    /// Keeps the rectangle inside the picture and big enough to grab.
    func setBlur(_ id: UUID, rect: CGRect) {
        guard let index = blurs.firstIndex(where: { $0.id == id }) else { return }
        let width = min(max(rect.width, 0.06), 1), height = min(max(rect.height, 0.06), 1)
        blurs[index].rect = CGRect(x: min(max(rect.minX, 0), 1 - width), y: min(max(rect.minY, 0), 1 - height), width: width, height: height)
    }

    // MARK: Watermark

    func chooseWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose a logo or picture to lay over the video")
        guard panel.runModal() == .OK, let file = panel.url else { return }
        watermarkFile = file
    }

    private func updateWatermarkImage() {
        switch watermarkMode {
        case .off:
            watermarkImage = nil
        case .text:
            let text = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
            watermarkImage = text.isEmpty ? nil : TextImage.render(text, size: 120, boxed: false)
        case .image:
            watermarkImage = watermarkFile.flatMap { NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        }
    }

    // MARK: Subtitles

    /// The speech as cues in the time of the saved clip: cut out parts are gone, speed is applied.
    func cues(for ranges: [Range<Double>]) -> [SubtitleCue] {
        guard let transcript else { return [] }
        var cues: [SubtitleCue] = []
        var offset = 0.0
        for range in ranges {
            for segment in transcript {
                let lower = max(segment.start, range.lowerBound), upper = min(segment.end, range.upperBound)
                guard upper - lower > 0.05 else { continue }
                cues.append(SubtitleCue(start: offset + (lower - range.lowerBound) / speed, end: offset + (upper - range.lowerBound) / speed, text: segment.text))
            }
            offset += (range.upperBound - range.lowerBound) / speed
        }
        guard reversed else { return cues }
        return cues.reversed().map { SubtitleCue(start: offset - $0.end, end: offset - $0.start, text: $0.text) }
    }

    private func transcribe() async {
        guard hasAudio else {
            subtitleMode = .off
            message = String(localized: "This video has no sound")
            return
        }
        guard !isTranscribing else { return }
        isTranscribing = true
        message = String(localized: "Listening to the speech…")
        defer { isTranscribing = false }
        do {
            let segments = try await Transcriber.transcribe(url)
            guard !segments.isEmpty else {
                subtitleMode = .off
                message = String(localized: "No speech found")
                return
            }
            transcript = segments
            message = nil
        } catch {
            subtitleMode = .off
            message = error.localizedDescription
        }
    }

    // MARK: Sound

    private func refreshLoudness() async {
        guard normalizes else {
            normalizeGain = 1
            return
        }
        let generation = soundGeneration
        isProcessingSound = true
        let gain = await VideoAudio.normalizeGain(for: replacementSound ?? cleanedSound ?? url)
        guard generation == soundGeneration else { return }
        normalizeGain = gain
        isProcessingSound = false
    }

    private func refreshNoise() async {
        soundGeneration += 1
        let generation = soundGeneration
        if let old = cleanedSound { try? FileManager.default.removeItem(at: old) }
        cleanedSound = nil
        guard reducesNoise else {
            isProcessingSound = false
            await refreshLoudness()
            return
        }
        isProcessingSound = true
        message = String(localized: "Reducing noise…")
        do {
            let cleaned = try await VideoAudio.denoised(url)
            guard generation == soundGeneration else {
                try? FileManager.default.removeItem(at: cleaned)
                return
            }
            cleanedSound = cleaned
            message = nil
        } catch {
            guard generation == soundGeneration else { return }
            message = error.localizedDescription
            reducesNoise = false
            return
        }
        // The level is measured on the cleaned sound.
        await refreshLoudness()
    }

    func chooseSoundtrack() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = String(localized: "Choose the sound to use instead of the clip's own")
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let other = AVURLAsset(url: file)
        guard (try? await other.loadTracks(withMediaType: .audio).first) != nil else {
            message = String(localized: "\(file.lastPathComponent) has no sound")
            return
        }
        replacementSound = file
        message = nil
        if normalizes { await refreshLoudness() }
    }

    func removeSoundtrack() {
        replacementSound = nil
        if normalizes { Task { await refreshLoudness() } }
    }

    /// Removes the temporary sound made by noise reduction.
    func cleanUp() {
        if let cleanedSound { try? FileManager.default.removeItem(at: cleanedSound) }
        cleanedSound = nil
    }

    func apply(_ preset: VideoPreset) {
        output = .mp4
        stripsMetadata = preset == .web
        switch preset {
        case .whatsApp: resolution = .p720; sizeLimitMB = 16
        case .telegram: resolution = .p1080; sizeLimitMB = nil
        case .reels: resolution = .p1080; crop = .vertical; sizeLimitMB = nil
        case .discord: resolution = .p720; sizeLimitMB = 10
        case .web: resolution = .p720; sizeLimitMB = nil
        }
        message = "\(preset.title): \(preset.detail)"
    }

    func restoreCuts() {
        cuts = []
        message = nil
    }

    /// A handle was let go: land exactly on its frame.
    func commitSeek() { seek(to: current) }

    func rotate() async {
        quarterTurns = (quarterTurns + 1) % 4
        await applyLayout()
    }

    func flip() async {
        flipped.toggle()
        await applyLayout()
    }

    private func applyLayout() async {
        guard let track, let item = player.currentItem else { return }
        layoutGeneration += 1
        let generation = layoutGeneration
        let composition = try? await VideoExporter.layout(
            source: track, target: track, duration: CMTime(seconds: duration, preferredTimescale: 600), edit: previewEdit)
        guard generation == layoutGeneration else { return }
        item.videoComposition = composition
        await loadThumbnails(layout: composition, generation: generation)
    }

    /// The preview plays at the chosen level, even above 100%.
    private func applyAudio() {
        guard let item = player.currentItem, let audioTrack else { return }
        item.audioMix = VideoExporter.audioMix(for: [audioTrack], duration: CMTime(seconds: duration, preferredTimescale: 600), edit: previewEdit)
    }

    func saveFrame() async {
        let output = OutputNamer.url(for: url, ext: "png", suffix: "Frame \(VideoEditorView.format(current))")
        do {
            try await VideoExporter.writeFrame(of: asset, at: CMTime(seconds: current, preferredTimescale: 600),
                                               layout: player.currentItem?.videoComposition, to: output)
            message = String(localized: "Saved \(output.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } catch {
            message = error.localizedDescription
        }
    }

    /// Writes the clip, or one file per part when it has been split. Joined clips go with the last part.
    func export() async throws -> [URL] {
        pause()
        isSaving = true
        defer { isSaving = false }

        let boundaries = [start] + splits.filter { $0 > start && $0 < end } + [end]
        let parts: [[Range<Double>]] = zip(boundaries, boundaries.dropFirst()).compactMap { lower, upper in
            let ranges = keptRanges.compactMap { kept -> Range<Double>? in
                let from = max(kept.lowerBound, lower), to = min(kept.upperBound, upper)
                return to - from > 0.05 ? from..<to : nil
            }
            return ranges.isEmpty ? nil : ranges
        }
        guard !parts.isEmpty else { throw ShiftioError.emptyResult(String(localized: "everything was cut out")) }

        var outputs: [URL] = []
        for (index, ranges) in parts.enumerated() {
            var partEdit = makeEdit(ranges: ranges)
            if index < parts.count - 1 { partEdit.joined = [] }
            let number = parts.count > 1 ? " \(index + 1)" : ""
            let suffix: String? = output.group == .audio ? (number.isEmpty ? nil : String(number.dropFirst())) : "Edited" + number
            let target = OutputNamer.url(for: url, ext: output.fileExtension, suffix: suffix)
            try await VideoExporter.export(url, edit: partEdit, to: target)
            outputs.append(target)
            if subtitleMode == .file {
                let lines = cues(for: ranges).map { Transcriber.Segment(text: $0.text, start: $0.start, end: $0.end) }
                if !lines.isEmpty {
                    let file = OutputNamer.url(for: target, ext: "srt")
                    try Transcriber.srt(lines).write(to: file, atomically: true, encoding: .utf8)
                    outputs.append(file)
                }
            }
        }
        return outputs
    }
}
