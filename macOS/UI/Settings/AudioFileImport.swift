import AppKit
import UniformTypeIdentifiers

/// Getting audio files from the user: a drop anywhere on the settings window,
/// or the open panel behind "Add Files…".
enum AudioFileImport {

    /// Collect the file URLs of a drop. Claims the drop at once; `completion`
    /// runs on the main queue once every item has loaded, in the order the
    /// files were dragged.
    static func handleDrop(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let identifier = UTType.fileURL.identifier
        let group = DispatchGroup()
        let lock = NSLock()
        // Keyed by index so the queue ends up in the order they were dragged,
        // not in whatever order the async loads happen to finish.
        var collected: [Int: URL] = [:]

        for (index, provider) in providers.enumerated() {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                defer { group.leave() }
                // Finder vends any of these three shapes depending on the OS
                // version; `loadObject(ofClass: URL.self)` is not dependable
                // before macOS 13.
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsurl = item as? NSURL {
                    url = nsurl as URL
                } else if let direct = item as? URL {
                    url = direct
                }
                guard let url else { return }
                lock.lock()
                collected[index] = url
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            let urls = collected.sorted { $0.key < $1.key }.map { $0.value }
            guard !urls.isEmpty else { return }
            // LSUIElement app: the permission alert and open panels need us
            // frontmost or they open behind whatever the user dragged from.
            NSApp.activate(ignoringOtherApps: true)
            completion(urls)
        }

        // Claim the drop now; the loads finish on their own.
        return true
    }

    /// The open panel; empty when the user cancels.
    static func chooseFiles() -> [URL] {
        // LSUIElement app: without this the panel opens behind everything.
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
            + AudioFileDecoder.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "test.file.chooseMessage".localized

        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
