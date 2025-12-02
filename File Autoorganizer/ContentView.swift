//
//  ContentView.swift
//  File Autoorganizer
//
//  Created by Christine on 12/2/25.
//

import SwiftUI
import AppKit
import PDFKit
import Quartz

fileprivate enum BookmarkKey: String { case sourceFolder, destinationRoot }

fileprivate func saveBookmark(for url: URL, key: BookmarkKey) {
    do {
        let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: key.rawValue)
    } catch {
        print("Failed to save bookmark for \(key): \(error)")
    }
}

fileprivate func resolveBookmark(key: BookmarkKey) -> URL? {
    guard let data = UserDefaults.standard.data(forKey: key.rawValue) else { return nil }
    var isStale = false
    do {
        let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale {
            // Re-save if stale
            saveBookmark(for: url, key: key)
        }
        return url
    } catch {
        print("Failed to resolve bookmark for \(key): \(error)")
        return nil
    }
}

// MARK: - Models

struct StatementFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let tokens: Set<String>
    let fileExtension: String
}

struct DestinationFolder: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let existingTokens: Set<String>
    let fileExtensions: Set<String>
}

struct ProposedMove: Identifiable, Hashable {
    let id = UUID()
    let file: StatementFile
    let destination: DestinationFolder?
    let score: Double
    let proposedNewName: String?
}

// MARK: - Naming Pattern & Date Extraction

fileprivate struct NamingPattern {
    // e.g., prefix "AcmeBank_Statement_", dateFormat "yyyy-MM", suffix ""
    let prefix: String
    let dateFormat: String
    let suffix: String
}

fileprivate func extractDate(fromText text: String) -> Date? {
    // Try common statement date patterns in order
    let patterns = [
        "(20\\d{2})[-/](0[1-9]|1[0-2])[-/](0[1-9]|[12]\\d|3[01])", // YYYY-MM-DD
        "(0[1-9]|1[0-2])[-/](0[1-9]|[12]\\d|3[01])[-/](20\\d{2})", // MM-DD-YYYY
        "(0[1-9]|1[0-2])[-/](20\\d{2})", // MM-YYYY
        "(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\\s+(20\\d{2})" // Month YYYY
    ]

    for pattern in patterns {
        if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
            let substr = String(text[range])
            // Normalize and parse
            let cleaned = substr.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "  ", with: " ")
            let fmts = [
                "yyyy-MM-dd", "yyyy/MM/dd",
                "MM-dd-yyyy", "MM/dd/yyyy",
                "MM-yyyy", "MM/yyyy",
                "MMM yyyy", "MMMM yyyy"
            ]
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            for f in fmts {
                df.dateFormat = f
                if let d = df.date(from: cleaned) { return d }
            }
        }
    }
    return nil
}

fileprivate func inferNamingPattern(in folder: URL) -> NamingPattern? {
    // Look at existing PDF filenames and try to infer a common prefix/suffix around a date pattern
    guard let contents = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
    let pdfs = contents.filter { $0.pathExtension.lowercased() == "pdf" }
    guard !pdfs.isEmpty else { return nil }

    // Common date formats we support in filenames
    let dateRegexes: [(regex: String, format: String)] = [
        ("20\\d{2}-\\d{2}-\\d{2}", "yyyy-MM-dd"),
        ("\\d{2}-\\d{2}-20\\d{2}", "MM-dd-yyyy"),
        ("20\\d{2}_\\d{2}_\\d{2}", "yyyy_MM_dd"),
        ("20\\d{2}-\\d{2}", "yyyy-MM"),
        ("\\d{2}-20\\d{2}", "MM-yyyy"),
        ("20\\d{2}\\d{2}\\d{2}", "yyyyMMdd"),
    ]

    // Try to find the most frequent (prefix, dateFormat, suffix)
    var counts: [String: (NamingPattern, Int)] = [:]

    for url in pdfs {
        let name = url.deletingPathExtension().lastPathComponent
        for (regex, format) in dateRegexes {
            if let r = name.range(of: regex, options: .regularExpression) {
                let prefix = String(name[..<r.lowerBound])
                let suffix = String(name[r.upperBound...])
                let key = "\(prefix)|\(format)|\(suffix)"
                let pattern = NamingPattern(prefix: prefix, dateFormat: format, suffix: suffix)
                let current = counts[key]?.1 ?? 0
                counts[key] = (pattern, current + 1)
            }
        }
    }

    // Choose the most common pattern
    if let best = counts.values.max(by: { $0.1 < $1.1 })?.0 {
        return best
    }

    // Fallback: simple pattern using folder name as prefix and yyyy-MM
    let folderName = folder.lastPathComponent
    return NamingPattern(prefix: folderName + "_", dateFormat: "yyyy-MM", suffix: "")
}

fileprivate func makeFilename(using pattern: NamingPattern, date: Date, originalExtension: String) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = pattern.dateFormat
    let dateString = df.string(from: date)
    return pattern.prefix + dateString + pattern.suffix + "." + originalExtension
}

fileprivate func makeUniqueDateString(date: Date, baseFormat: String, counter: Int) -> String {
    let df = DateFormatter()
    df.locale = Locale(identifier: "en_US_POSIX")
    df.dateFormat = baseFormat
    let base = df.string(from: date)
    return base + "_" + String(format: "%02d", counter)
}

fileprivate func computeProposedName(for fileURL: URL, destinationFolderURL: URL) -> String? {
    // Extract date from first page text
    var date: Date? = nil
    if let pdf = PDFDocument(url: fileURL), let page = pdf.page(at: 0), let text = page.string {
        date = extractDate(fromText: text)
    }
    if date == nil {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
        }
    }
    let finalDate = date ?? Date()

    // Infer naming pattern in destination folder
    let pattern = inferNamingPattern(in: destinationFolderURL) ?? NamingPattern(prefix: destinationFolderURL.lastPathComponent + "_", dateFormat: "yyyy-MM", suffix: "")

    // Build a target filename with date and resolve collisions
    let originalExt = fileURL.pathExtension
    var targetName = makeFilename(using: pattern, date: finalDate, originalExtension: originalExt)
    var targetURL = destinationFolderURL.appendingPathComponent(targetName)
    var counter = 1
    while FileManager.default.fileExists(atPath: targetURL.path) {
        targetName = pattern.prefix + makeUniqueDateString(date: finalDate, baseFormat: pattern.dateFormat, counter: counter) + pattern.suffix + "." + originalExt
        targetURL = destinationFolderURL.appendingPathComponent(targetName)
        counter += 1
    }
    return targetName
}

// MARK: - Similarity Helpers

fileprivate func tokenize(fileName: String) -> Set<String> {
    // Kept for fallback and destination profiling when PDF text fails
    fileName
        .lowercased()
        .replacingOccurrences(of: ".", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty && $0.count > 1 }
        .reduce(into: Set<String>()) { $0.insert($1) }
}

fileprivate func tokenizePDF(url: URL, pages: Int = 3) -> Set<String> {
    guard let pdf = PDFDocument(url: url) else { return [] }
    var combined = ""
    let pageCount = min(pages, pdf.pageCount)
    for i in 0..<pageCount {
        if let page = pdf.page(at: i), let text = page.string {
            combined.append(" ")
            combined.append(text)
        }
    }
    let lowered = combined.lowercased()
    let tokens = lowered
        .components(separatedBy: CharacterSet.whitespacesAndNewlines)
        .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
        .filter { !$0.isEmpty && $0.count >= 2 }
    return Set(tokens)
}

fileprivate func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
    let inter = a.intersection(b).count
    let uni = a.union(b).count
    return uni == 0 ? 0.0 : Double(inter) / Double(uni)
}

fileprivate func score(statement: StatementFile, destination: DestinationFolder) -> Double {
    let nameScore = jaccardSimilarity(statement.tokens, destination.existingTokens)
    let extScore = destination.fileExtensions.contains(statement.fileExtension.lowercased()) ? 0.2 : 0.0
    let folderTokens = tokenize(fileName: destination.url.lastPathComponent)
    let anchorOverlap = statement.tokens.intersection(folderTokens).isEmpty ? 0.0 : 0.1
    return nameScore + extScore + anchorOverlap
}

fileprivate func buildDestinationFolders(root: URL) -> [DestinationFolder] {
    var folders: [DestinationFolder] = []

    if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
        var folderMap: [URL: (Set<String>, Set<String>)] = [:]

        for case let fileURL as URL in enumerator {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
                // Only consider PDFs in the destination tree per requirements
                if fileURL.pathExtension.lowercased() == "pdf" {
                    let contentTokens = tokenizePDF(url: fileURL)
                    let nameTokens = tokenize(fileName: fileURL.deletingPathExtension().lastPathComponent)
                    let dirURL = fileURL.deletingLastPathComponent()
                    let folderTokens = tokenize(fileName: dirURL.lastPathComponent)
                    let tokens = (contentTokens.isEmpty ? nameTokens : contentTokens).union(folderTokens)
                    let ext = fileURL.pathExtension.lowercased()
                    var entry = folderMap[dirURL] ?? ([], [])
                    entry.0.formUnion(tokens)
                    if !ext.isEmpty { entry.1.insert(ext) }
                    folderMap[dirURL] = entry
                }
            }
        }

        folders = folderMap.map { (dir, data) in
            DestinationFolder(url: dir, existingTokens: data.0, fileExtensions: data.1)
        }
    }

    for dest in folders {
        print("DEST FOLDER:", dest.url.path, "tokenCount:", dest.existingTokens.count, "exts:", Array(dest.fileExtensions))
    }
    if folders.isEmpty {
        print("No destination PDFs found under:", root.path)
    }

    return folders
}

fileprivate func proposeMoves(sourceFolder: URL, destinationRoot: URL, threshold: Double) -> [ProposedMove] {
    let destinations = buildDestinationFolders(root: destinationRoot)

    guard let enumerator = FileManager.default.enumerator(at: sourceFolder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
        return []
    }

    var proposals: [ProposedMove] = []

    for case let fileURL as URL in enumerator {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue {
            // Only consider PDFs per requirements
            guard fileURL.pathExtension.lowercased() == "pdf" else { continue }

            let stmt = StatementFile(
                url: fileURL,
                tokens: tokenizePDF(url: fileURL),
                fileExtension: fileURL.pathExtension.lowercased()
            )

            let best = destinations
                .map { ($0, score(statement: stmt, destination: $0)) }
                .max(by: { $0.1 < $1.1 })

            if let (dest, s) = best {
                print("SOURCE:", fileURL.lastPathComponent, "BEST DEST:", dest.url.lastPathComponent, "score:", s)
            } else {
                print("SOURCE:", fileURL.lastPathComponent, "No destinations considered")
            }

            if let (dest, s) = best, s >= threshold {
                let name = computeProposedName(for: fileURL, destinationFolderURL: dest.url)
                proposals.append(ProposedMove(file: stmt, destination: dest, score: s, proposedNewName: name))
            } else {
                let s = best?.1 ?? 0
                proposals.append(ProposedMove(file: stmt, destination: nil, score: s, proposedNewName: nil))
            }
        }
    }

    // Sort by confidence descending
    return proposals.sorted { $0.score > $1.score }
}

// MARK: - Quick Look Support

fileprivate final class URLPreviewItem: NSObject, QLPreviewItem {
    let url: URL
    init(url: URL) { self.url = url }
    var previewItemURL: URL? { url }
}

fileprivate final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var items: [URL] = []
    var currentIndex: Int = 0

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        return URLPreviewItem(url: items[index])
    }
}

// MARK: - ContentView

struct ContentView: View {
    // Default source to Downloads
    @State private var sourceFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: "~/Downloads")
    @State private var destinationRoot: URL? = nil

    @State private var threshold: Double = 0.35
    @State private var proposals: [ProposedMove] = []
    @State private var selections: Set<UUID> = []
    @State private var isScanning: Bool = false
    @State private var isMoving: Bool = false
    @State private var errorMessage: String? = nil
    @State private var infoMessage: String? = nil

    // Quick Look state
    @State private var quickLookCoordinator = QuickLookCoordinator()
    @State private var selectedPreviewURL: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PDF Statement Auto-Organizer")
                .font(.title2).bold()

            HStack(spacing: 12) {
                LabeledPathPicker(title: "Source", url: $sourceFolder, canChooseFiles: false)
                LabeledPathPicker(title: "Destination Root", url: Binding(
                    get: { destinationRoot ?? URL(fileURLWithPath: "/") },
                    set: { destinationRoot = $0 }
                ), canChooseFiles: false)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Threshold: " + String(format: "%.0f%%", threshold * 100))
                    Slider(value: $threshold, in: 0...1, step: 0.05)
                        .frame(maxWidth: 280)
                }

                Button {
                    scan()
                } label: {
                    if isScanning { ProgressView().controlSize(.small) } else { Text("Scan") }
                }
                .disabled(destinationRoot == nil || isScanning)

                Spacer()

                Button(role: .none) {
                    applySelectedMoves()
                } label: {
                    if isMoving { ProgressView().controlSize(.small) } else { Text("Move Selected") }
                }
                .disabled(selections.isEmpty || isMoving)
            }

            // Legend explaining score colors and threshold
            HStack(spacing: 16) {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 10, height: 10)
                    Text("≥ 60% (high confidence)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle().fill(Color.blue).frame(width: 10, height: 10)
                    Text("≥ 35% (above mid band)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle().fill(Color.secondary).frame(width: 10, height: 10)
                    Text("15–35% (low–mid confidence)").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 10, height: 10)
                    Text("< 15% (very low)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Threshold: " + String(format: "%.0f%%", threshold * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            if let infoMessage {
                Text(infoMessage).foregroundStyle(.secondary)
            }

            List {
                Section(header: Text("Proposed Moves (Preview)").font(.headline)) {
                    ForEach(proposals) { move in
                        MoveRow(
                            move: move,
                            isSelected: Binding(
                                get: { selections.contains(move.id) },
                                set: { newValue in
                                    if newValue { selections.insert(move.id) } else { selections.remove(move.id) }
                                }
                            ),
                            onPreview: {
                                selectedPreviewURL = move.file.url
                                presentQuickLook(for: [move.file.url])
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedPreviewURL = move.file.url
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .onAppear {
            // Resolve bookmarks if available
            if let savedSource = resolveBookmark(key: .sourceFolder) { sourceFolder = savedSource }
            if let savedDest = resolveBookmark(key: .destinationRoot) { destinationRoot = savedDest }
            installKeyMonitor()
        }
        .onDisappear { removeKeyMonitor() }
        .padding()
    }

    private func scan() {
        guard let destinationRoot else {
            errorMessage = "Please choose a destination root folder."
            return
        }
        errorMessage = nil
        infoMessage = nil
        isScanning = true
        selections.removeAll()

        DispatchQueue.global(qos: .userInitiated).async {
            let srcURL = sourceFolder
            let dstURL = destinationRoot
            let srcAccess = srcURL.startAccessingSecurityScopedResource()
            let dstAccess = dstURL.startAccessingSecurityScopedResource()
            defer {
                if srcAccess { srcURL.stopAccessingSecurityScopedResource() }
                if dstAccess { dstURL.stopAccessingSecurityScopedResource() }
            }

            let newProposals = proposeMoves(sourceFolder: srcURL, destinationRoot: dstURL, threshold: threshold)
            DispatchQueue.main.async {
                self.proposals = newProposals
                // Preselect only those with a destination (above threshold)
                self.selections = Set(newProposals.filter { $0.destination != nil }.map { $0.id })
                self.isScanning = false
                self.infoMessage = newProposals.isEmpty ? "No PDFs found or no confident matches." : "Found \(newProposals.count) PDFs with suggestions."
            }
        }
    }

    private func applySelectedMoves() {
        guard let destinationRoot else { return }
        isMoving = true
        errorMessage = nil
        infoMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let srcURL = sourceFolder
            let dstURL = destinationRoot
            let srcAccess = srcURL.startAccessingSecurityScopedResource()
            let dstAccess = dstURL.startAccessingSecurityScopedResource()
            defer {
                if srcAccess { srcURL.stopAccessingSecurityScopedResource() }
                if dstAccess { dstURL.stopAccessingSecurityScopedResource() }
            }

            var moved: [(from: URL, to: URL)] = []
            var failures: [(url: URL, error: Error)] = []

            for move in proposals where selections.contains(move.id) {
                guard let dest = move.destination else { continue }

                // Extract date from PDF text (first page), fall back to file creation or modification date
                var date: Date? = nil
                if let pdf = PDFDocument(url: move.file.url), let page = pdf.page(at: 0), let text = page.string {
                    date = extractDate(fromText: text)
                }
                if date == nil {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: move.file.url.path) {
                        date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
                    }
                }
                let finalDate = date ?? Date()

                // Infer naming pattern in destination folder
                let pattern = inferNamingPattern(in: dest.url) ?? NamingPattern(prefix: dest.url.lastPathComponent + "_", dateFormat: "yyyy-MM", suffix: "")

                // Build a target filename with date and resolve collisions
                let originalExt = move.file.url.pathExtension
                var targetName = makeFilename(using: pattern, date: finalDate, originalExtension: originalExt)
                var targetURL = dest.url.appendingPathComponent(targetName)
                var counter = 1
                while FileManager.default.fileExists(atPath: targetURL.path) {
                    targetName = pattern.prefix + makeUniqueDateString(date: finalDate, baseFormat: pattern.dateFormat, counter: counter) + pattern.suffix + "." + originalExt
                    targetURL = dest.url.appendingPathComponent(targetName)
                    counter += 1
                }

                do {
                    try FileManager.default.createDirectory(at: dest.url, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: move.file.url, to: targetURL)
                    moved.append((from: move.file.url, to: targetURL))
                } catch {
                    failures.append((url: move.file.url, error: error))
                }
            }

            DispatchQueue.main.async {
                self.isMoving = false
                if !failures.isEmpty {
                    self.errorMessage = "Failed to move \(failures.count) file(s). For example: \(failures.first!.url.lastPathComponent) — \(failures.first!.error.localizedDescription)"
                }
                if !moved.isEmpty {
                    self.infoMessage = "Moved \(moved.count) file(s)."
                }
                // After moving, rescan to refresh list
                self.scan()
            }
        }
    }

    // MARK: - Quick Look helpers
    @State private var keyMonitor: Any?

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 { // Space bar
                toggleQuickLook()
                return nil // consume
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func toggleQuickLook() {
        guard let url = selectedPreviewURL ?? proposals.first(where: { selections.contains($0.id) })?.file.url else { return }
        presentQuickLook(for: [url])
    }

    private func presentQuickLook(for urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        quickLookCoordinator.items = urls
        quickLookCoordinator.currentIndex = 0
        panel.dataSource = quickLookCoordinator
        panel.delegate = quickLookCoordinator
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Subviews

private struct LabeledPathPicker: View {
    let title: String
    @Binding var url: URL
    let canChooseFiles: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title + ":")
            Text(url.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minWidth: 240, alignment: .leading)
            Button("Choose…") { pickFolder() }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = canChooseFiles
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = url
        panel.begin { response in
            if response == .OK, let picked = panel.url {
                url = picked
                // Save security-scoped bookmark
                if title.lowercased().contains("source") {
                    saveBookmark(for: picked, key: .sourceFolder)
                } else if title.lowercased().contains("destination") {
                    saveBookmark(for: picked, key: .destinationRoot)
                }
            }
        }
    }
}

private struct MoveRow: View {
    let move: ProposedMove
    @Binding var isSelected: Bool
    let onPreview: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: $isSelected).labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                Text(move.file.url.lastPathComponent)
                if let _ = move.destination {
                    Text(move.destination!.url.path).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No confident match (will not move)").font(.caption).foregroundStyle(.orange)
                }
                if let dest = move.destination, let newName = move.proposedNewName {
                    Text("→ \(newName)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button("Preview") {
                onPreview()
            }
            .buttonStyle(.link)
            Spacer()
            Text(String(format: "%.1f%%", move.score * 100))
                .monospaced()
                .foregroundStyle(colorForScore(move.score))
                .help({
                    let scoreText = String(format: "Score: %.6f", move.score)
                    let destinationName = move.destination?.url.lastPathComponent ?? "—"
                    let destinationText = "Destination: \(destinationName)"
                    return "\(scoreText)\n\(destinationText)"
                }())
                .onAppear {
                    print("UI ROW:", move.file.url.lastPathComponent, "score:", move.score)
                }
        }
    }

    private func colorForScore(_ s: Double) -> Color {
        switch s {
        case 0.6...: return .green
        case 0.35...: return .blue
        case 0.15...: return .secondary
        default: return .orange
        }
    }
}

#Preview {
    ContentView()
}

struct AutoOrganizerIcon: View {
    var body: some View {
        ZStack {
            // Folder base (adaptive tint)
            Image(systemName: "folder.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)

            // PDF sheet subtly peeking
            Image(systemName: "doc.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.white)
                .frame(width: 44, height: 56)
                .offset(x: 14, y: -6)

            // Small badge suggesting automation/processing
            Image(systemName: "doc.badge.gearshape.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.red)
                .font(.system(size: 16, weight: .semibold))
                .offset(x: 18, y: 18)
        }
        .frame(width: 80, height: 70)
        .tint(Color(nsColor: .controlAccentColor)) // adaptive accent color
        .accessibilityLabel("Auto-organizer icon: folder with automated PDF handling")
    }
}

#Preview("Icon Preview") {
    AutoOrganizerIcon()
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
}
