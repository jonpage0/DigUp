import Observation
import Photos

/// "Download from iCloud", for a picture or video of the Photos library whose original isn't on this Mac (DigUp read
/// Photos' preview, stills or poster of it). Photos fetches the original from iCloud and keeps it in the library, as it
/// does when the item is opened in Photos; the library's folders change, the next sync's listing finds the original,
/// and the same record is read again from it (`photos_assets.reading` becomes original or edited). DigUp keeps no
/// copy: what PhotoKit hands over is dropped. It asks for the version Photos shows (an edit's render, else the
/// original), which is the one DigUp reads first.
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

    func state(of uuid: String) -> State? { states[uuid] }

    func start(_ uuid: String) {
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
            let outcome = await (asset.mediaType == .video ? Self.video(asset, progress) : Self.picture(asset, progress))
            finish(uuid, outcome)
        }
    }

    private func finish(_ uuid: String, _ state: State) {
        states[uuid] = state
        if case .failed(let why) = state { log("photos: download failed: \(why)") } else { log("photos: downloaded") }
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

    private nonisolated static func video(_ asset: PHAsset, _ progress: @escaping @Sendable (Double) -> Void) async -> State {
        let options = PHVideoRequestOptions()
        options.version = .current
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value, _, _, _ in progress(value) }
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, info in
                continuation.resume(returning: video != nil ? .done : .failed(Self.reason(info)))
            }
        }
    }

    private nonisolated static func reason(_ info: [AnyHashable: Any]?) -> String {
        if info?[PHImageCancelledKey] as? Bool == true { return "Cancelled" }
        return (info?[PHImageErrorKey] as? Error)?.localizedDescription ?? "Photos didn't download it"
    }
}
