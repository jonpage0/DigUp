import AVFoundation
import Observation
import Photos

/// "Download from iCloud", for a picture or video of the Photos library whose original isn't on this Mac (DigUp read
/// Photos' preview, stills or poster of it). Photos fetches the original from iCloud and keeps it in the library, as it
/// does when the item is opened in Photos; the library's folders change, the next sync's listing finds the original,
/// and the same record is read again from it (`photos_assets.reading` becomes original or edited). DigUp keeps no
/// copy: what PhotoKit hands over is dropped, except a video's file URL, which Quick Look plays until the app quits
/// (Space on a video in iCloud downloads it and then shows the video, Jon 2026-10-22). It asks for the version Photos
/// shows (an edit's render, else the original), which is the one DigUp reads first.
///
/// PhotoKit reaches only the System Photo Library, so an item of another library isn't found. Photos may remove the
/// original again later ("Optimize Mac Storage"); the record then goes back to the preview it has.
@MainActor @Observable
final class PhotosDownloads {
    static let shared = PhotosDownloads()

    enum State: Equatable {
        case downloading(Double)
        case done
        case failed(String)
    }

    /// By asset uuid, for as long as the app runs.
    private(set) var states: [String: State] = [:]
    /// A downloaded video's file, by asset uuid (PhotoKit's URL for it: the library's original, or a render of it).
    private var videos: [String: URL] = [:]
    /// What to do when a download ends, by asset uuid (Quick Look waiting to show the video).
    private var waiting: [String: [() -> Void]] = [:]

    func state(of uuid: String) -> State? { states[uuid] }

    /// The file of a video downloaded since the app started: the version Photos shows, or for a slow-motion video, which
    /// PhotoKit hands over as a composition with no single file, its original (played at the speed it was recorded).
    func video(of uuid: String) -> URL? { videos[uuid] }

    /// Starts the download (once at a time per item); `then` runs when it ends, however it ends.
    func start(_ uuid: String, then: (() -> Void)? = nil) {
        if let then { waiting[uuid, default: []].append(then) }
        if case .downloading = states[uuid] { return }
        states[uuid] = .downloading(0)
        Task {
            let access = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard access == .authorized || access == .limited else {
                return finish(uuid, .failed("DigUp isn't allowed to use Photos (System Settings › Privacy & Security › Photos)"))
            }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: ["\(uuid)/L0/001"], options: nil).firstObject else {
                return finish(uuid, .failed("Photos can download only from its System Photo Library"))
            }
            log("photos: downloading \(asset.mediaType == .video ? "a video" : "a picture") from iCloud")
            let progress: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    if case .downloading = PhotosDownloads.shared.states[uuid] {
                        PhotosDownloads.shared.states[uuid] = .downloading(value)
                    }
                }
            }
            if asset.mediaType == .video {
                let (state, url) = await Self.video(asset, progress)
                if let url { videos[uuid] = url }
                finish(uuid, state)
            } else {
                finish(uuid, await Self.picture(asset, progress))
            }
        }
    }

    private func finish(_ uuid: String, _ state: State) {
        states[uuid] = state
        if case .failed(let why) = state { log("photos: download failed: \(why)") } else { log("photos: downloaded") }
        for then in waiting.removeValue(forKey: uuid) ?? [] { then() }
    }

    private nonisolated static func picture(_ asset: PHAsset, _ progress: @escaping @Sendable (Double) -> Void) async -> State {
        let options = PHImageRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in progress(value) }
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                continuation.resume(returning: data != nil ? .done : .failed(Self.reason(info)))
            }
        }
    }

    /// What PhotoKit gave for one version of a video: its file, a video with no single file, or why it gave nothing.
    private enum Video: Sendable {
        case file(URL)
        case noFile
        case failed(String)
    }

    private nonisolated static func video(_ asset: PHAsset, _ progress: @escaping @Sendable (Double) -> Void) async
        -> (State, URL?) {
        switch await request(asset, .current, progress) {
        case .file(let url): return (.done, url)
        case .failed(let why): return (.failed(why), nil)
        case .noFile:
            if case .file(let url) = await request(asset, .original, progress) { return (.done, url) }
            return (.done, nil)
        }
    }

    private nonisolated static func request(_ asset: PHAsset, _ version: PHVideoRequestOptionsVersion,
                                            _ progress: @escaping @Sendable (Double) -> Void) async -> Video {
        let options = PHVideoRequestOptions()
        options.version = version
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in progress(value) }
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, info in
                guard let video else { return continuation.resume(returning: .failed(Self.reason(info))) }
                continuation.resume(returning: (video as? AVURLAsset).map { .file($0.url) } ?? .noFile)
            }
        }
    }

    private nonisolated static func reason(_ info: [AnyHashable: Any]?) -> String {
        if info?[PHImageCancelledKey] as? Bool == true { return "Cancelled" }
        return (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "Photos didn't download it"
    }
}
