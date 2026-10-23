import AppKit
import ApplicationServices

/// The music streaming apps the player can show and control. Both have an AppleScript dictionary; other services
/// (Tidal, Deezer, a browser tab) offer nothing a program can ask for.
enum Streamer: String, CaseIterable, Identifiable {
    case music, spotify
    var id: String { rawValue }

    var name: String { self == .music ? "Apple Music" : "Spotify" }
    var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
    private var scriptName: String { self == .music ? "Music" : "Spotify" }

    var runningApp: NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first }
    var isRunning: Bool { runningApp != nil }

    enum Access { case allowed, denied, undecided, notRunning }

    /// Whether Shiftio may send Apple events to the app. Without `ask` this never shows a dialog; with it, the system
    /// asks once (and blocks until answered, so call it off the main thread). The app has to be running to be asked about.
    func access(ask: Bool = false) -> Access {
        guard isRunning else { return .notRunning }
        var address = AEAddressDesc()
        let created = bundleID.withCString { AECreateDesc(DescType(typeApplicationBundleID), $0, strlen($0), &address) }
        guard created == noErr else { return .notRunning }
        defer { AEDisposeDesc(&address) }
        let status = AEDeterminePermissionToAutomateTarget(&address, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent): return .undecided
        case OSStatus(procNotFound): return .notRunning
        default: return .denied
        }
    }

    /// One line of fields separated by tabs: state, title, artist, album, length, position, and (Spotify) the cover's address.
    var statusScript: String {
        let length = self == .spotify ? "(duration of t) / 1000" : "duration of t"
        let cover = self == .spotify ? " & tab & (artwork url of t)" : ""
        return """
        with timeout of 2 seconds
        tell application "\(scriptName)"
        if player state is stopped then return "stopped"
        set t to current track
        set n to 0
        try
        set n to \(length)
        end try
        return (player state as text) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & (n as text) & tab & (player position as text)\(cover)
        end tell
        end timeout
        """
    }

    func command(_ line: String) -> String {
        "with timeout of 2 seconds\ntell application \"\(scriptName)\" to \(line)\nend timeout"
    }

    func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct LyricLine: Equatable, Identifiable {
    let id: Int
    /// nil when the lyrics carry no timing.
    let time: Double?
    let text: String
}

struct QueueItem: Equatable, Identifiable {
    let id: Int
    let title: String
    let artist: String
    /// Position in the playlist, to play it.
    var position = 0
}

enum PlayerPane: String, CaseIterable, Identifiable {
    case lyrics, queue
    var id: String { rawValue }
    var title: String { self == .lyrics ? String(localized: "Lyrics") : String(localized: "Up Next") }
}

enum LyricsState: Equatable {
    case idle, loading, missing
    case found([LyricLine])
}

struct NowPlayingTrack: Equatable {
    var source: Streamer
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var artworkURL: URL?
    var measuredAt = Date.now

    /// Where the playhead is now, carried on from the last reading while the track plays.
    func position(at date: Date) -> Double {
        let moved = isPlaying ? date.timeIntervalSince(measuredAt) : 0
        return min(max(position + moved, 0), duration > 0 ? duration : position + moved)
    }
}

/// What is playing in Apple Music or Spotify, asked of the apps while the player is on screen. It only talks to an app
/// that is running and that the user has allowed; asking permission is always the user's own click.
@MainActor @Observable
final class NowPlayingService {
    private(set) var track: NowPlayingTrack?
    /// Drives the glass's appearing and disappearing, like the ring's `isVisible`.
    var isShown = false
    /// The ring has been put away and only the player is on screen.
    var isMini = false
    /// The mini player stays on screen until it is unpinned: clicks elsewhere, Esc and the ring closing leave it alone.
    var isPinned = false
    /// The pinned player is being dragged: nothing else touches the window until it is let go.
    var isDragging = false
    /// Called when the dragging ends, with the window where it was let go.
    @ObservationIgnored var onDragEnd: () -> Void = {}
    /// The speed of the pointer, in points per second, as the pinned player was let go.
    @ObservationIgnored var releaseVelocity = CGVector.zero
    /// The player's window really has the keys. Liquid Glass only draws fully (lensing, bright edge) then; otherwise macOS draws
    /// it as flat frosted glass, and the pieces add their own highlights to still read as glass.
    var isKey = true
    private(set) var cover: NSImage?
    /// A running app that has not been allowed yet; the player offers a button for it.
    private(set) var needsPermission: Streamer?
    /// Called after every reading, so the panel can show, hide and resize.
    @ObservationIgnored var onChange: () -> Void = {}

    private var polling: Task<Void, Never>?
    private var coverKey: String?
    private var coverTask: Task<Void, Never>?
    private var sample = false

    var hasContent: Bool { track != nil || needsPermission != nil }

    /// Clicking the player opens a second part under it with the lyrics or the queue.
    private(set) var expanded = false
    /// Height of the lyrics or queue list, set by the panel from the room on screen.
    var paneHeight: CGFloat = 170
    var pane = PlayerPane.lyrics { didSet { paneChanged() } }
    private(set) var lyrics = LyricsState.idle
    private(set) var queue: [QueueItem] = []
    /// Why the queue is empty, when it is known (Spotify keeps its queue to itself).
    private(set) var queueNote: String?
    /// Whether the source can say what plays next (Apple Music, when playing from a playlist or album). Without it the tab is hidden.
    private(set) var hasQueue = false
    private var lyricsKey: String?
    private var lyricsTask: Task<Void, Never>?

    func toggleExpanded() {
        expanded.toggle()
        paneChanged()
        onChange()
    }

    private func paneChanged() {
        guard expanded, let track else { return }
        if pane == .lyrics { loadLyrics(for: track) }
        // Asked even while the lyrics show, to know whether there is a queue tab to offer.
        Task { await refreshQueue(for: track) }
    }

    /// How often the apps are asked. A pinned player stays up for long stretches, so it asks rarely and relies on the apps'
    /// own announcements of a new track or a pause for the rest (the position is carried on locally between readings).
    private var pollSeconds: Double { isPinned ? 6 : 1 }
    @ObservationIgnored private var announcements: [NSObjectProtocol] = []

    func start() {
        guard polling == nil, !sample else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(self?.pollSeconds ?? 1))
            }
        }
        guard announcements.isEmpty else { return }
        for name in ["com.apple.Music.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            announcements.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            })
        }
    }

    func stop() {
        polling?.cancel()
        polling = nil
        announcements.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        announcements = []
        coverTask?.cancel()
        lyricsTask?.cancel()
        expanded = false
        guard !sample else { return }
        // The last track, cover and state are kept, so the player is on screen the instant the ring opens and is corrected
        // a moment later by the first reading. Waiting for that reading made it appear after the ring.
        if cover == nil { coverKey = nil }
        if lyrics == .loading {
            lyrics = .idle
            lyricsKey = nil
        }
    }

    /// A made-up track for screenshots (`-ShiftioPreviewPlayer`).
    func useSample(expanded: Bool = false, pane: PlayerPane = .lyrics) {
        sample = true
        self.expanded = expanded
        self.pane = pane
        // The lines are invented (not the song's real lyrics), so nothing in a screenshot reproduces someone's words.
        lyrics = .found([LyricLine(id: 0, time: 0, text: "Lanterns over the quiet bay"), LyricLine(id: 1, time: 20, text: "Every window learns your name"),
                         LyricLine(id: 2, time: 40, text: "We keep the night a little longer"),
                         LyricLine(id: 3, time: 62, text: "Hold the light, don't let it fade"),
                         LyricLine(id: 4, time: 80, text: "Somewhere past the river road"),
                         LyricLine(id: 5, time: 100, text: "The morning finds us anyway")])
        queue = [QueueItem(id: 0, title: "Save Your Tears", artist: "The Weeknd"), QueueItem(id: 1, title: "Starboy", artist: "The Weeknd, Daft Punk"),
                 QueueItem(id: 2, title: "Take My Breath", artist: "The Weeknd")]
        hasQueue = true
        track = NowPlayingTrack(source: .spotify, title: "Blinding Lights", artist: "The Weeknd", album: "After Hours",
                                duration: 200, position: 64, isPlaying: true)
        onChange()
    }

    private func refresh() async {
        var best: NowPlayingTrack?
        var blocked: Streamer?
        for streamer in Streamer.allCases {
            switch streamer.access() {
            case .allowed:
                guard let found = await Self.read(streamer) else { continue }
                if best == nil || (found.isPlaying && best?.isPlaying == false) { best = found }
            case .undecided:
                blocked = blocked ?? streamer
            case .denied, .notRunning:
                break
            }
        }
        guard !Task.isCancelled else { return }
        // An app that is still running but gave no usable answer this time (between two tracks, "stopped" for a moment, a script
        // that timed out) does not take the player off the screen: the last track stays until the app really goes away.
        if best == nil, let old = track, old.source.isRunning {
            var kept = old
            kept.position = old.position(at: .now)
            kept.measuredAt = .now
            kept.isPlaying = false
            best = kept
        }
        track = best
        needsPermission = best == nil ? blocked : nil
        if let best {
            loadCover(for: best)
            if expanded {
                if pane == .lyrics { loadLyrics(for: best) }
                if pane == .queue || !hasQueue { await refreshQueue(for: best) }
            }
        } else {
            cover = nil
            coverKey = nil
        }
        onChange()
    }

    private static func read(_ streamer: Streamer) async -> NowPlayingTrack? {
        let asked = Date.now
        guard let line = await Osascript.run(streamer.statusScript) else { return nil }
        // The app reads its position somewhere in the middle of the call; stamping the reading when the answer arrived made
        // everything that follows the song (the lyrics, the bar) run late by the time the call took.
        let measured = asked.addingTimeInterval(Date.now.timeIntervalSince(asked) / 2)
        let fields = line.components(separatedBy: "\t")
        guard fields.count >= 6 else { return nil }
        func number(_ text: String) -> Double { Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        var found = NowPlayingTrack(source: streamer, title: fields[1], artist: fields[2], album: fields[3], duration: number(fields[4]),
                                    position: number(fields[5]), isPlaying: fields[0] == "playing",
                                    artworkURL: fields.count > 6 ? URL(string: fields[6]) : nil)
        found.measuredAt = measured
        return found
    }

    // MARK: Cover

    private func loadCover(for track: NowPlayingTrack) {
        let key = [track.source.rawValue, track.artist, track.album, track.artworkURL?.absoluteString ?? ""].joined(separator: "|")
        guard key != coverKey else { return }
        coverKey = key
        coverTask?.cancel()
        coverTask = Task { [weak self] in
            let image = await Self.fetchCover(for: track)
            guard !Task.isCancelled, let image else { return }
            self?.cover = image
        }
    }

    /// Spotify gives the picture's address. Apple Music is asked for the picture itself first (it has one for most tracks), then
    /// the public iTunes catalogue is searched by song and by album.
    private static func fetchCover(for track: NowPlayingTrack) async -> NSImage? {
        if let given = track.artworkURL { return await download(given) }
        if track.source == .music, let image = await musicArtwork() { return image }
        for entity in ["song", "album"] {
            if let url = await searchCover(track: track, entity: entity), let image = await download(url) { return image }
        }
        return nil
    }

    private static func download(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    /// The picture of the current track, written to a file by Music itself.
    private static func musicArtwork() async -> NSImage? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("NowPlaying")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("cover-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: file) }
        let script = """
        with timeout of 3 seconds
        tell application "Music"
        try
        set d to raw data of artwork 1 of current track
        on error
        return "none"
        end try
        end tell
        set f to open for access POSIX file "\(file.path)" with write permission
        set eof f to 0
        write d to f
        close access f
        return "ok"
        end timeout
        """
        guard await Osascript.run(script) == "ok", let data = try? Data(contentsOf: file) else { return nil }
        return NSImage(data: data)
    }

    private static func searchCover(track: NowPlayingTrack, entity: String) async -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        let term = entity == "song" ? "\(track.artist) \(track.title)" : "\(track.artist) \(track.album)"
        components?.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "entity", value: entity),
                                  URLQueryItem(name: "limit", value: "1")]
        guard let url = components?.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (object["results"] as? [[String: Any]])?.first, let small = first["artworkUrl100"] as? String
        else { return nil }
        return URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    // MARK: Lyrics and queue

    private func loadLyrics(for track: NowPlayingTrack) {
        let key = [track.source.rawValue, track.title, track.artist].joined(separator: "|")
        guard key != lyricsKey else { return }
        lyricsKey = key
        lyricsTask?.cancel()
        lyrics = .loading
        lyricsTask = Task { [weak self] in
            let lines = await Self.fetchLyrics(for: track)
            guard !Task.isCancelled, let self else { return }
            lyrics = lines.isEmpty ? .missing : .found(lines)
            onChange()
        }
    }

    /// From lrclib.net, a free public lyrics catalogue. Timed lyrics (`[01:23.45] line`) are used when it has them.
    /// Track names from streaming services carry extras ("(feat. …)", "- Remastered", several artists) that the catalogue does
    /// not, so the lookup goes from the exact name to a cleaned one to looser searches, and picks the best match by length.
    private static func fetchLyrics(for track: NowPlayingTrack) async -> [LyricLine] {
        let title = cleanedTitle(track.title)
        let artist = primaryArtist(track.artist)
        let wantedLength = track.duration

        var candidates: [[String: Any]] = []
        // 1. The exact record, by the names as the app gives them, then cleaned.
        for (name, performer) in [(track.title, track.artist), (title, artist)] {
            if let found = await get("get", ["track_name": name, "artist_name": performer, "album_name": track.album,
                                             "duration": String(Int(wantedLength.rounded()))]) as? [String: Any] {
                candidates.append(found)
                break
            }
        }
        // 2. Searches, from strict to loose.
        if candidates.isEmpty {
            let searches: [[String: String]] = [
                ["track_name": title, "artist_name": artist],
                ["q": "\(artist) \(title)"],
                ["track_name": title],
                ["q": title],
            ]
            for query in searches {
                if let found = await get("search", query) as? [[String: Any]], !found.isEmpty {
                    candidates += found
                    if bestMatch(in: candidates, title: title, length: wantedLength) != nil { break }
                }
            }
        }
        var lines: [LyricLine] = []
        if let best = bestMatch(in: candidates, title: title, length: wantedLength) { lines = lyricLines(from: best) }
        // A second catalogue, with a lot of Russian and Asian music that lrclib lacks.
        if lines.isEmpty { lines = await netEaseLyrics(title: title, artist: artist, length: wantedLength) }
        // Apple Music keeps the lyrics of some songs itself.
        if lines.isEmpty, track.source == .music { lines = await musicLyrics() }
        return lines
    }

    private static func get(_ endpoint: String, _ query: [String: String]) async -> Any? {
        var components = URLComponents(string: "https://lrclib.net/api/\(endpoint)")
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url, let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The candidate that is the right song: close in length first, timed lyrics preferred, and a title that really matches.
    private static func bestMatch(in candidates: [[String: Any]], title: String, length: Double) -> [String: Any]? {
        let wanted = normalized(title)
        let usable = candidates.filter {
            ($0["syncedLyrics"] as? String)?.isEmpty == false || ($0["plainLyrics"] as? String)?.isEmpty == false
        }
        let named = usable.filter {
            let found = normalized(cleanedTitle(($0["trackName"] as? String) ?? ($0["name"] as? String) ?? ""))
            return found.isEmpty || found.contains(wanted) || wanted.contains(found)
        }
        let pool = named.isEmpty ? [] : named
        return pool.min { score($0, length: length) < score($1, length: length) }
    }

    /// Lower is better: how far the length is off, with a bonus for timed lyrics.
    private static func score(_ candidate: [String: Any], length: Double) -> Double {
        let off = abs((candidate["duration"] as? Double ?? length) - length)
        let timed = (candidate["syncedLyrics"] as? String)?.isEmpty == false
        return off - (timed ? 3 : 0)
    }

    private static func lyricLines(from record: [String: Any]) -> [LyricLine] {
        if let synced = record["syncedLyrics"] as? String, !synced.isEmpty {
            let timed = parseTimed(synced)
            if !timed.isEmpty { return timed }
        }
        let plain = (record["plainLyrics"] as? String) ?? ""
        return plain.components(separatedBy: .newlines).enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// NetEase Cloud Music's public search and lyric endpoints. Timed lyrics when it has them.
    private static func netEaseLyrics(title: String, artist: String, length: Double) async -> [LyricLine] {
        guard let search = URL(string: "https://music.163.com/api/search/get") else { return [] }
        var request = URLRequest(url: search)
        request.httpMethod = "POST"
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "s", value: "\(artist) \(title)"), URLQueryItem(name: "type", value: "1"),
                           URLQueryItem(name: "limit", value: "8"), URLQueryItem(name: "offset", value: "0")]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let songs = (object["result"] as? [String: Any])?["songs"] as? [[String: Any]] else { return [] }
        let wanted = normalized(title)
        // Right name and about the right length, closest first; each is tried until one has lyrics.
        let matches = songs.filter {
            let found = normalized(cleanedTitle($0["name"] as? String ?? ""))
            let seconds = ($0["duration"] as? Double ?? 0) / 1000
            return (found.contains(wanted) || wanted.contains(found)) && abs(seconds - length) < 6
        }.sorted { abs(($0["duration"] as? Double ?? 0) / 1000 - length) < abs(($1["duration"] as? Double ?? 0) / 1000 - length) }
        for song in matches.prefix(3) {
            guard let id = song["id"] as? Int,
                  let url = URL(string: "https://music.163.com/api/song/lyric?id=\(id)&lv=1&kv=1&tv=-1"),
                  let (lyricData, _) = try? await URLSession.shared.data(from: url),
                  let record = try? JSONSerialization.jsonObject(with: lyricData) as? [String: Any],
                  let text = (record["lrc"] as? [String: Any])?["lyric"] as? String, !text.isEmpty else { continue }
            let timed = parseTimed(text)
            if !timed.isEmpty { return timed }
        }
        return []
    }

    private static func musicLyrics() async -> [LyricLine] {
        let script = """
        with timeout of 3 seconds
        tell application "Music" to return lyrics of current track
        end timeout
        """
        // A track without lyrics comes back as the word "missing value", which is not lyrics.
        guard let text = await Osascript.run(script), text != "missing value" else { return [] }
        return text.components(separatedBy: .newlines).enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// "Song (feat. X) - Remastered 2011 [Explicit]" → "Song".
    static func cleanedTitle(_ title: String) -> String {
        var text = title
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+[-–—]\s+.*$"#, #"\s+(feat\.?|ft\.?|prod\.?)\s+.*$"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// "Aarne, Toxi$ & Big Baby Tape" → "Aarne".
    static func primaryArtist(_ artist: String) -> String {
        let first = artist.components(separatedBy: CharacterSet(charactersIn: ",&;/"))[0]
            .replacingOccurrences(of: #"\s+(feat\.?|ft\.?|x|and)\s+.*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return first.isEmpty ? artist : first
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func parseTimed(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.components(separatedBy: .newlines) {
            guard raw.hasPrefix("["), let close = raw.firstIndex(of: "]") else { continue }
            let stamp = raw[raw.index(after: raw.startIndex)..<close].split(separator: ":")
            guard stamp.count == 2, let minutes = Double(stamp[0]), let seconds = Double(stamp[1]) else { continue }
            let line = raw[raw.index(after: close)...].trimmingCharacters(in: .whitespaces)
            lines.append(LyricLine(id: lines.count, time: minutes * 60 + seconds, text: line))
        }
        return lines
    }

    /// What plays after the current track. Only Apple Music says; Spotify's scripting has no queue.
    private func refreshQueue(for track: NowPlayingTrack) async {
        guard track.source == .music else {
            queue = []
            hasQueue = false
            pane = .lyrics
            return
        }
        let script = """
        with timeout of 3 seconds
        tell application "Music"
        set cp to current playlist
        set firstIdx to (index of current track) + 1
        set total to count of tracks of cp
        set lastIdx to firstIdx + 11
        if lastIdx > total then set lastIdx to total
        set out to ""
        repeat with i from firstIdx to lastIdx
        set t to track i of cp
        set out to out & (name of t) & tab & (artist of t) & tab & i & linefeed
        end repeat
        return out
        end tell
        end timeout
        """
        guard let text = await Osascript.run(script) else {
            queue = []
            hasQueue = false
            if pane == .queue { pane = .lyrics }
            onChange()
            return
        }
        queue = text.components(separatedBy: .newlines).filter { !$0.isEmpty }.enumerated().map { offset, line in
            let parts = line.components(separatedBy: "\t")
            return QueueItem(id: offset, title: parts.first ?? "", artist: parts.count > 1 ? parts[1] : "",
                             position: Int(parts.count > 2 ? parts[2] : "") ?? 0)
        }
        queueNote = queue.isEmpty ? String(localized: "Nothing is queued after this track.") : nil
        hasQueue = !queue.isEmpty
        if !hasQueue, pane == .queue { pane = .lyrics }
        onChange()
    }

    // MARK: Controls

    func playPause() {
        guard var current = track else { return }
        current.position = current.position(at: .now)
        current.measuredAt = .now
        current.isPlaying.toggle()
        track = current
        send(current.source.command("playpause"))
    }

    func next() { if let track { send(track.source.command("next track")) } }

    /// Plays a track from the queue list: it is jumped to inside the playlist that is playing.
    func play(_ item: QueueItem) {
        guard let track, track.source == .music, item.position > 0 else { return }
        send(track.source.command("play (track \(item.position) of current playlist)"))
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
        }
    }
    func previous() { if let track { send(track.source.command("previous track")) } }

    /// A tap on a line of the lyrics jumps to it.
    func seek(toSeconds seconds: Double) {
        guard let track, track.duration > 0 else { return }
        seek(toFraction: seconds / track.duration)
    }

    func seek(toFraction fraction: Double) {
        guard var current = track, current.duration > 0 else { return }
        let seconds = min(max(fraction, 0), 1) * current.duration
        current.position = seconds
        current.measuredAt = .now
        track = current
        send(current.source.command("set player position to \(String(format: "%.2f", seconds))"))
    }

    /// Called when the mini-player button was pressed: the ring goes, the player stays.
    @ObservationIgnored var onDetach: () -> Void = {}

    /// Called when the pin was toggled.
    @ObservationIgnored var onPinChange: (Bool) -> Void = { _ in }

    func togglePin() {
        isPinned.toggle()
        onPinChange(isPinned)
    }

    /// Called to close the ring when the cover was pressed.
    @ObservationIgnored var onDismiss: () -> Void = {}

    /// The cover: the ring closes and the streaming app comes forward.
    func openAppAndClose() {
        openApp()
        onDismiss()
    }

    func openApp() { (track?.source ?? needsPermission)?.open() }

    /// Asks macOS to let Shiftio control the app. Shows the system's own question.
    func allow(_ streamer: Streamer) {
        Task.detached {
            _ = streamer.access(ask: true)
            await self.refresh()
        }
    }

    private func send(_ script: String) {
        guard !sample else { return }
        Task { _ = await Osascript.run(script) }
    }
}

enum Osascript {
    /// Runs a script and returns what it printed, or nil when it failed. Off the main thread.
    static func run(_ script: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            nonisolated(unsafe) let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
                continuation.resume(returning: finished.terminationStatus == 0 ? text : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
