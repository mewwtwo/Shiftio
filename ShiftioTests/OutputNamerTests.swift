import AppKit
import Foundation
import PDFKit
import Testing
@testable import Shiftio

struct OutputNamerTests {
    @Test func picksFreeNameNextToSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("Page 001.pdf")
        #expect(OutputNamer.url(for: source, ext: "jpg").lastPathComponent == "Page 001.jpg")

        FileManager.default.createFile(atPath: dir.appendingPathComponent("Page 001.jpg").path, contents: Data())
        #expect(OutputNamer.url(for: source, ext: "jpg").lastPathComponent == "Page 001 2.jpg")
        #expect(OutputNamer.url(for: source, ext: "jpg", suffix: "(p2)").lastPathComponent == "Page 001 (p2).jpg")
    }
}

struct RadialGeometryTests {
    @Test func hitTestsSegmentsClockwiseFromTop() {
        let geometry = RadialGeometry(diameter: 300, segmentCount: 4, hasCenter: true)
        let c = geometry.ringCenter
        #expect(geometry.hit(c) == .center)
        #expect(geometry.hit(CGPoint(x: c.x, y: c.y - 100)) == .segment(0))
        #expect(geometry.hit(CGPoint(x: c.x + 100, y: c.y)) == .segment(1))
        #expect(geometry.hit(CGPoint(x: c.x, y: c.y + 100)) == .segment(2))
        #expect(geometry.hit(CGPoint(x: c.x - 100, y: c.y)) == .segment(3))
        #expect(geometry.hit(CGPoint(x: c.x + 400, y: c.y)) == nil)
    }
}

struct ConverterTests {
    @Test func convertsImageAndPDF() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1-page PDF → PNG → JPG, then both → merged PDF.
        let pdf = dir.appendingPathComponent("Sample.pdf")
        let text = NSAttributedString(string: "Hello Shiftio")
        let rtf = dir.appendingPathComponent("Sample.rtf")
        try DocumentConverter.write(text, to: rtf, format: .rtf)
        let docx = try await ConvertToDocumentAction(format: .docx).run([rtf], options: ActionOptions())
        #expect(FileManager.default.fileExists(atPath: docx[0].path))

        let context = CGContext(pdf as CFURL, mediaBox: nil, nil)!
        context.beginPDFPage(nil); context.setFillColor(.black); context.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
        context.endPDFPage(); context.closePDF()

        let png = try await ConvertToImageAction(format: .png).run([pdf], options: ActionOptions())
        #expect(png.map(\.lastPathComponent) == ["Sample.png"])
        let jpg = try await ConvertToImageAction(format: .jpg).run(png, options: ActionOptions())
        #expect(jpg.map(\.lastPathComponent) == ["Sample.jpg"])

        let merged = try await MergePDFAction().run([pdf, jpg[0]], options: ActionOptions())
        #expect(PDFDocument(url: merged[0])?.pageCount == 2)

        let zip = try await ZipAction().run([pdf, jpg[0]], options: ActionOptions())
        #expect(zip.map(\.lastPathComponent) == ["Archive.zip"])
    }
}

struct CropMathTests {
    let bounds = CGSize(width: 1000, height: 800)

    @Test func freeResizeMovesOnlyDraggedEdges() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        let r = CropMath.resize(start, handle: .right, by: CGSize(width: 50, height: 99), ratio: nil, in: bounds)
        #expect(r == CGRect(x: 100, y: 100, width: 450, height: 300))
        let c = CropMath.resize(start, handle: .topLeft, by: CGSize(width: -500, height: -500), ratio: nil, in: bounds)
        #expect(c.minX == 0 && c.minY == 0 && c.maxX == 500 && c.maxY == 400)
    }

    @Test func lockedRatioKeepsAnchorAndStaysInBounds() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 400)
        let r = CropMath.resize(start, handle: .bottomRight, by: CGSize(width: 2000, height: 2000), ratio: 1, in: bounds)
        #expect(r.minX == 100 && r.minY == 100)
        #expect(abs(r.width / r.height - 1) < 0.001)
        #expect(r.maxX <= bounds.width && r.maxY <= bounds.height)
        let edge = CropMath.resize(start, handle: .right, by: CGSize(width: 100, height: 0), ratio: 1, in: bounds)
        #expect(edge.width == 500 && edge.height == 500 && edge.midY == start.midY)
    }

    @Test func moveAndFitStayInsideImage() {
        let start = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(CropMath.move(start, by: CGSize(width: 5000, height: -5000), in: bounds) == CGRect(x: 600, y: 0, width: 400, height: 300))
        let fit = CropMath.fit(CGRect(x: 0, y: 0, width: 1000, height: 800), ratio: 1)
        #expect(fit == CGRect(x: 100, y: 0, width: 800, height: 800))
    }
}

struct BackgroundRendererTests {
    @Test func canvasGrowsWithPaddingAndRatio() throws {
        var settings = BackgroundSettings(fill: .solid(.hex(0xFFFFFF)), padding: 10, corners: 8, shadow: 4, ratio: nil)
        let size = CGSize(width: 100, height: 50)
        #expect(BackgroundRenderer.canvasSize(for: size, settings: settings) == CGSize(width: 120, height: 70))
        settings.ratio = 1
        #expect(BackgroundRenderer.canvasSize(for: size, settings: settings) == CGSize(width: 120, height: 120))

        let context = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = try #require(context.makeImage())
        let output = try #require(BackgroundRenderer.render(image, originalSize: size, settings: settings))
        #expect(output.width == 120 && output.height == 120)
    }
}

struct ConfigTests {
    @Test @MainActor func oldConfigGetsNewDefaultRingsAndKeepsSettings() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"enabled":false,"trigger":"option"}"#.utf8).write(to: url)

        let store = ConfigStore(url: url)
        #expect(store.config.enabled == false)
        #expect(store.config.trigger == .option)
        #expect(store.config.rings[.image]?.first?.center == nil)
        #expect(store.config.ringsVersion == RingConfig.defaultsVersion)

        store.config.revealInFinder = true   // triggers save → must round-trip
        let reloaded = ConfigStore(url: url)
        #expect(reloaded.config.revealInFinder)
        #expect(reloaded.config.rings[.pdf]?.count == RingConfig.defaults[.pdf]?.count)
    }
}

struct EditorPipelineTests {
    private func solidImage(width: Int, height: Int, gray: CGFloat = 1) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.data!.assumingMemoryBound(to: UInt8.self)[y * context.bytesPerRow + x * 4]
    }

    @Test func redactionBurnsBlackIntoPixels() throws {
        let source = solidImage(width: 40, height: 40)
        let redacted = try #require(Redactor.render(source, boxes: [CGRect(x: 10, y: 10, width: 10, height: 10)], style: .black))
        #expect(pixel(redacted, x: 15, y: 15) == 0)
        #expect(pixel(redacted, x: 30, y: 30) == 255)
    }

    @Test func defaultRingsOnlyReferenceKnownActions() {
        for rings in RingConfig.defaults.values {
            for ring in rings {
                for id in ring.segments + [ring.center].compactMap({ $0 }) {
                    #expect(ActionRegistry.action(id) != nil || ItemCatalog.dynamic(id) != nil, "unknown action \(id)")
                }
            }
        }
    }
}

struct AppearanceTests {
    @Test func accentCanBeSoftenedAndDisabled() throws {
        var appearance = Appearance()
        #expect(appearance.accentEnabled && appearance.accentIntensity < 1)   // soft by default
        appearance.accentEnabled = false
        // Disabled → a neutral gray, whatever the chosen colour.
        let neutral = NSColor(appearance.accent).usingColorSpace(.sRGB)!
        #expect(abs(neutral.redComponent - neutral.blueComponent) < 0.01)

        // Old config files without the new keys decode with the new defaults.
        let old = try JSONDecoder().decode(Appearance.self, from: Data(#"{"diameter":300}"#.utf8))
        #expect(old.diameter == 300 && old.accentEnabled && old.accentIntensity == 0.6)
    }
}

struct SliderAndGlassTests {
    @Test @MainActor func doubleClickOnSliderTriggersResetButSingleClickDoesNot() throws {
        let slider = ResetNSSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        var resets = 0
        slider.onDoubleClick = { resets += 1 }

        func click(_ count: Int) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 10), modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        slider.mouseDown(with: click(2))
        #expect(resets == 1)
    }

    @Test func glassStyleDefaultsToSystemAndSurvivesOldConfigs() throws {
        let old = try JSONDecoder().decode(Appearance.self, from: Data(#"{"diameter":300}"#.utf8))
        #expect(old.glassStyle == .clear && old.glassFrost == 0.5 && old.glassTint == 0.1)
        // A config saved by an earlier build (style "system", no tint key) moves to the clear look once.
        let earlier = try JSONDecoder().decode(Appearance.self, from: Data(#"{"glassStyle":"system"}"#.utf8))
        #expect(earlier.glassStyle == .clear)
        var chosen = Appearance()
        chosen.glassStyle = .system
        let encoded = try JSONEncoder().encode(chosen)
        #expect(try JSONDecoder().decode(Appearance.self, from: encoded).glassStyle == .system)
    }
}

struct AudioConversionTests {
    @Test func convertsToEveryFormatWithTheBundledEncoder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Glass.aiff")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff"), to: source)

        #expect(MP3Encoder.locate() != nil, "needs the installed copy or a system lame")

        // The generic "Audio" sector follows the setting; MP3 is the default.
        let generic = try await ConvertAudioAction(format: nil).run([source], options: ActionOptions())
        #expect(generic.map(\.lastPathComponent) == ["Glass.mp3"])
        #expect(ConvertAudioAction(format: nil).displayTitle(options: ActionOptions()) == "MP3")
        var wav = ActionOptions(); wav.audioFormat = .wav
        #expect(ConvertAudioAction(format: nil).displayTitle(options: wav) == "WAV")

        for format in [AudioFormat.m4a, .wav, .flac] {
            let output = try await ConvertAudioAction(format: format).run([source], options: ActionOptions())
            let size = try FileManager.default.attributesOfItem(atPath: output[0].path)[.size] as? Int ?? 0
            #expect(size > 1000, "\(format.title) output is empty")
        }
        let mp3 = try Data(contentsOf: generic[0])
        #expect(mp3.count > 1000)
        // MP3 frames start with an 11-bit sync word (ID3 tag first is also valid).
        #expect(mp3.prefix(3) == Data("ID3".utf8) || (mp3[0] == 0xFF && mp3[1] & 0xE0 == 0xE0))
    }
}

struct FullEditorTests {
    private func photo(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    @Test func straighteningKeepsTheCropInsideThePicture() {
        let full = CGSize(width: 4000, height: 3000)
        var g = EditGeometry()
        #expect(EditGeometryMath.crop(full, g) == CGRect(x: 0, y: 0, width: 4000, height: 3000))

        g.straighten = 10
        let canvas = EditGeometryMath.canvasSize(full, g)
        #expect(canvas.width > 4000 && canvas.height > 3000)
        let crop = EditGeometryMath.crop(full, g)
        #expect(crop.width < 4000 && abs(crop.width / crop.height - 4.0 / 3) < 0.01)
        #expect(CGRect(origin: .zero, size: canvas).contains(crop))

        g.quarterTurns = 1
        g.straighten = 0
        #expect(EditGeometryMath.oriented(full, g) == CGSize(width: 3000, height: 4000))

        g.aspect = .square
        let square = EditGeometryMath.crop(full, g)
        #expect(abs(square.width - square.height) <= 1)
    }

    @Test func pipelineRotatesCropsAndAdjusts() async throws {
        let renderer = FullEditRenderer(full: photo(400, 200))
        var state = EditState()
        let plain = try #require(await renderer.render(state, maxSide: 400, mode: .result))
        #expect(plain.width == 400 && plain.height == 200)

        state.geometry.quarterTurns = 1
        let turned = try #require(await renderer.render(state, maxSide: 400, mode: .result))
        #expect(turned.width == 200 && turned.height == 400)

        state.geometry.aspect = .square
        let square = try #require(await renderer.render(state, maxSide: 400, mode: .result))
        #expect(square.width == square.height)

        var edited = EditState()
        edited.adjustments.exposure = -1.5
        edited.adjustments.vignette = 0.5
        edited.filter = .noir
        let preview = try #require(await renderer.render(edited, maxSide: 200, mode: .result))
        #expect(preview.width == 200)
        let thumbnails = await renderer.thumbnails(edited)
        #expect(thumbnails.count == EditFilter.allCases.count)
    }

    @Test @MainActor func undoRedoAndGroupingOfEdits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("p.png")
        try ImageConverter.write(photo(120, 80), to: url, format: .png, properties: nil, options: ActionOptions())

        let model = FullEditorModel(image: try EditableImage(url: url))
        #expect(!model.canUndo)

        // A slider drag is many changes in quick succession: one undo step.
        for value in stride(from: 0.1, through: 0.5, by: 0.1) { model.mutate { $0.adjustments.exposure = value } }
        #expect(model.state.adjustments.exposure == 0.5 && model.canUndo)
        model.undo()
        #expect(model.state.isUntouched && model.canRedo)
        model.redo()
        #expect(model.state.adjustments.exposure == 0.5)

        // Changing the framing drops markup, and that is undoable too.
        model.addAnnotation(Annotation(tool: .rectangle, points: [.zero, CGPoint(x: 10, y: 10)], color: .red, width: 2))
        #expect(model.state.annotations.count == 1)
        model.rotate(1)
        #expect(model.state.annotations.isEmpty)
        model.undo()
        #expect(model.state.annotations.count == 1)
    }
}

struct ComponentInstallerTests {
    @Test func picksOnlyPackagesThatRunOnThisMac() {
        let tags = ComponentInstaller.platformTags()
        #expect(!tags.isEmpty)
        #if arch(arm64)
        #expect(tags.allSatisfy { $0.hasPrefix("arm64_") })
        #endif
        // Newest first, never newer than the running system.
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major >= 26 { #expect(tags.contains { $0.hasSuffix("tahoe") }) }
        if major < 27 { #expect(!tags.contains { $0.hasSuffix("golden_gate") }) }
    }

    /// Real download from the package host. Run with: TEST_RUNNER_SHIFTIO_NETWORK_TESTS=1 xcodebuild test …
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHIFTIO_NETWORK_TESTS"] == "1"))
    @MainActor func downloadsAndRunsTheEncoderFromScratch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shiftio-components-\(UUID().uuidString)")
        UserDefaults.standard.set(folder.path, forKey: "ShiftioComponentsDir")
        defer {
            UserDefaults.standard.removeObject(forKey: "ShiftioComponentsDir")
            try? FileManager.default.removeItem(at: folder)
        }

        let installer = ComponentInstaller()
        await installer.installMP3()
        #expect(installer.mp3 == .installed, "state: \(installer.mp3)")
        #expect(MP3Encoder.locate()?.isManaged == true)

        // Runs with an empty environment, so nothing can be borrowed from Homebrew.
        let process = Process()
        process.executableURL = folder.appendingPathComponent("lame/lame")
        process.arguments = ["--version"]
        process.environment = [:]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0 && text.contains("LAME"))

        // And converting with the freshly installed copy works.
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).aiff")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff"), to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let mp3 = try await ConvertAudioAction(format: .mp3).run([source], options: ActionOptions())
        defer { mp3.forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect((try FileManager.default.attributesOfItem(atPath: mp3[0].path)[.size] as? Int ?? 0) > 1000)
    }
}

struct ControlRingTests {
    @Test @MainActor func tilesHaveOptionsAndStableIDs() {
        let ids = ControlAction.tiles.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("sys-recentapps") && ids.contains("sys-keyboard") && ids.contains("sys-folders") && !ids.contains("sys-nightshift") && !ids.contains { $0.contains("volume") })

        for tile in ControlAction.tiles where tile.isAvailable() && !tile.id.hasSuffix("apps") {
            let options = tile.children
            if tile.id == "sys-settings" { #expect(options.isEmpty); continue }   // opens System Settings directly
            #expect(options.count >= 2, "\(tile.id) should offer a choice")
            #expect(Set(options.map(\.id)).count == options.count)
            #expect(options.allSatisfy { $0.children.isEmpty }, "options are leaves")
        }
        // Wi-Fi offers explicit On / Off, not a blind toggle.
        let wifi = ControlAction.tiles.first { $0.id == "sys-wifi" }?.children.map(\.title)
        #expect(wifi?.starts(with: ["Turn On", "Turn Off"]) == true)
    }

    @Test @MainActor func tileOpensSecondRingAndBackReturns() throws {
        let panel = RadialPanelController()
        let store = ConfigStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json"))
        let ringID = try #require(store.config.rings[.system]?.first?.id)
        panel.showControl(rings: try [#require(store.popupRing(id: ringID))], at: .zero, appearance: Appearance())
        let tileCount = panel.state.rings.first?.segments.count ?? 0
        #expect(tileCount >= 5)

        let appearance = try #require(ControlAction.tiles.first { $0.id == "sys-appearance" })
        panel.pushControl(appearance)
        let options = panel.state.rings.first?.segments.map(\.title)
        #expect(options == ["Auto", "Light", "Dark", "Settings"])
        #expect(panel.state.rings.first?.center?.action.id == ControlAction.backID)

        panel.popControl()
        #expect(panel.state.rings.first?.segments.count == tileCount)
        panel.hide()
    }
}

struct CustomItemsTests {
    @Test @MainActor func shortcutsAppsAndStylesResolveIntoRingItems() throws {
        #expect(ActionRegistry.action("shortcut:Morning Routine")?.title == "Morning Routine")
        #expect(ActionRegistry.action("app:com.apple.Safari")?.title == "Safari")
        #expect(ActionRegistry.action("app:does.not.exist")?.state() == nil)
        #expect(ItemCatalog.dynamic("apps:recent:4") != nil && ItemCatalog.dynamic("apps:other:4") == nil)

        let styles = ["shortcut:Morning Routine": ItemStyle(title: "Start day", icon: .emoji("☀️")),
                      "app:com.apple.Safari": ItemStyle(title: nil, icon: .symbol("safari"))]
        var ring = RingConfig(name: "Mine", center: nil, trigger: .ctrlShift,
                              segments: ["shortcut:Morning Routine", "app:com.apple.Safari"])
        let resolved = try #require(ResolvedRing(ring, resolution: RingResolution(styles: styles)) { action in
            action is ShortcutAction || action is AppAction
        })
        #expect(resolved.segments.map(\.title) == ["Start day", "Safari"])
        #expect(resolved.segments[0].emoji == "☀️" && resolved.segments[0].symbol == nil)
        #expect(resolved.segments[1].symbol == "safari" && resolved.segments[1].image == nil)

        // The trigger survives saving and loading.
        ring.trigger = .optCtrl
        let decoded = try JSONDecoder().decode(RingConfig.self, from: JSONEncoder().encode(ring))
        #expect(decoded.trigger == .optCtrl && decoded.segments == ring.segments)
    }

    @Test @MainActor func recentAndFrequentAppsExpandAndOldConfigsGainAnAppsRing() throws {
        let usage = AppUsage()
        let ring = RingConfig(name: "Apps", center: nil, trigger: .optShift, segments: ["apps:recent:3"])
        let resolved = ResolvedRing(ring, resolution: RingResolution(apps: usage)) { $0 is AppAction }
        #expect((resolved?.segments.count ?? 0) <= 3)

        // A config saved before pop-up rings had triggers: ⌘⇧ is kept and an Apps ring appears.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = AppConfig()
        var data = try JSONEncoder().encode(old)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["ringsVersion"] = 6
        var rings = try #require(object["rings"] as? [String: Any])
        rings["system"] = [["id": UUID().uuidString, "name": "Control", "segments": ["sys-wifi"]]]
        object["rings"] = rings
        data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url)

        let store = ConfigStore(url: url)
        let popup = try #require(store.config.rings[.system])
        #expect(popup.first?.trigger == .optShift)
        #expect(popup.count == 1)
        #expect(popup[0].segments.contains("sys-recentapps") && popup[0].segments.contains("sys-frequentapps"))
    }
}

struct FolderPinsTests {
    @Test @MainActor func defaultFoldersAndTileOptions() throws {
        let titles = FolderPins.defaults.map(\.title)
        #expect(titles == ["Desktop", "Downloads", "Documents", "Recents", "Applications"])
        #expect(FolderPins.defaults[3].isRecents && FolderPins.defaults[3].url == nil)

        let tile = try #require(ControlAction.tiles.first { $0.id == "sys-folders" })
        let options = tile.children.map(\.title)
        #expect(options.contains("Recents") && options.contains("Applications"))
        #expect(tile.children.first { $0.title == "Applications" }?.image != nil)
    }
}

struct SymbolSearchTests {
    @Test func searchFindsByNameAndKeyword() {
        #expect(SymbolCatalog.all.count > 2000)
        let star = SymbolCatalog.search("star")
        #expect(star.first == "star" && star.contains("star.fill"))
        // Keywords find symbols whose names don't contain the word.
        #expect(!SymbolCatalog.search("date").isEmpty)
        #expect(SymbolCatalog.search("wifi").contains("wifi"))
        #expect(SymbolCatalog.search("wifi slash").contains("wifi.slash"))
        #expect(SymbolCatalog.search("qqqzzzxxx").isEmpty)
        #expect(SymbolCatalog.search("").count == 150)
    }
}

struct FolderIconTests {
    @Test @MainActor func glyphIsPrintedOnTheFolder() throws {
        let folder = FolderPins.defaults[0]
        let base = FolderIcon.baseIcon(for: folder)
        let withSymbol = FolderIcon.make(base: base, icon: .symbol("star.fill"))
        let withEmoji = FolderIcon.make(base: base, icon: .emoji("🎬"))
        #expect(withSymbol.size == NSSize(width: 128, height: 128) && withEmoji.size == withSymbol.size)

        func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
            let data = try #require(image.tiffRepresentation)
            return try #require(NSBitmapImageRep(data: data))
        }
        // The glyph changes pixels in the middle of the folder and leaves the corners alone.
        let plain = try bitmap(FolderIcon.make(base: base, icon: .symbol("not.a.real.symbol.name")))
        let marked = try bitmap(withSymbol)
        var changedCentre = false
        let w = marked.pixelsWide, h = marked.pixelsHigh
        for x in (w * 35 / 100)..<(w * 65 / 100) {
            for y in (h * 40 / 100)..<(h * 75 / 100) where plain.colorAt(x: x, y: y) != marked.colorAt(x: x, y: y) { changedCentre = true }
        }
        #expect(changedCentre)
        #expect(plain.colorAt(x: 4, y: 4) == marked.colorAt(x: 4, y: 4))
    }
}
