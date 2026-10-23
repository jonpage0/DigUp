import Foundation

/// What's said in a recording, as words with the times they're said: read by parakeet-mlx
/// (https://github.com/senstella/parakeet-mlx, Apache-2.0), which runs NVIDIA's Parakeet TDT 0.6B v3 (`model`: 25
/// European languages, its weights under CC BY 4.0) on the Mac's GPU. It's a program of its own, installed once like
/// osxphotos (`installCommand`), and it decodes recordings with ffmpeg; DigUp looks for both (`parakeet`, `ffmpeg`)
/// whenever indexing starts, and without them nothing changes. The first time it reads anything it downloads the model
/// (`modelBytes`) into the Hugging Face cache.
///
/// Measured 2026-10-22 on an M3 Max (parakeet-mlx 0.5.3, the model downloaded): 86 s of speech in 1.8 s and 10 minutes
/// in 9.9 s, its start included, about 60 times faster than it plays; 4–6 GB of memory at its peak, in its own process.
///
/// Only a recording on this Mac is read (`Indexer`: an audio file, a video's own file, a Photos video once it's
/// downloaded), never a video that's only in iCloud, read from Photos' stills of it. What it hears is kept as stretches
/// (`stretches(of:)`): `speech` segments, each with its words, for keyword search and to show, and a text vector, as a
/// document's passage has.
public enum Speech {
    /// The model DigUp has parakeet-mlx run (Jon, 2026-10-22: "parakeet v3"), as Hugging Face names it: NVIDIA's
    /// weights, converted for MLX. Also parakeet-mlx's default.
    public static let model = "mlx-community/parakeet-tdt-0.6b-v3"
    /// What it downloads the first time: the weights and their tokenizer (Hugging Face's sizes, 2026-10-22).
    public static let modelBytes: Int64 = 2_509_044_141
    /// The commands that install parakeet-mlx and ffmpeg, as the app shows them.
    public static let installCommand = "uv tool install parakeet-mlx"
    public static let ffmpegInstallCommand = "brew install ffmpeg"

    /// parakeet-mlx, where `InstalledPrograms` finds it: $DIGUP_PARAKEET names one (empty: none).
    public static var parakeet: String? { InstalledPrograms.path(of: "parakeet-mlx", chosenBy: "DIGUP_PARAKEET") }
    /// ffmpeg, which parakeet-mlx runs to decode a recording, where `InstalledPrograms` finds it.
    public static var ffmpeg: String? { InstalledPrograms.path(of: "ffmpeg") }

    // MARK: Stretches

    /// A stretch of speech holds consecutive sentences up to about `longest` seconds or `mostWords` words, and never runs
    /// across a silence longer than `longestSilence` seconds: short enough that its moment says where something was
    /// said, long enough to say what it's about.
    static let longest = 30.0
    static let mostWords = 60
    static let longestSilence = 2.0

    /// A sentence as parakeet-mlx writes it (`--output-format json`): its tokens, pieces of words and punctuation, each
    /// with when it's said, in seconds. Its text is theirs, one after the other.
    struct Sentence: Decodable, Sendable, Equatable {
        struct Token: Decodable, Sendable, Equatable {
            let text: String
            let start: Double
            let end: Double

            /// It holds some of a word, not just punctuation. A full stop is a token of its own, and it can come after
            /// a pause, just before the next sentence starts: a sentence is timed by its words alone.
            var isWordy: Bool { text.contains(where: Sentence.isWordy) }
        }

        let tokens: [Token]

        /// It, cut wherever its words pause for longer than `longestSilence`, punctuation going with the words before
        /// it. parakeet-mlx cuts a sentence at a silence between any two tokens, so a comma heard in the middle of a
        /// pause keeps the words either side of it in one sentence.
        var cutAtPauses: [Sentence] {
            var pieces: [[Token]] = [[]]
            var lastWord: Token?
            for token in tokens {
                if token.isWordy, let lastWord, token.start - lastWord.end > Speech.longestSilence { pieces.append([]) }
                pieces[pieces.count - 1].append(token)
                if token.isWordy { lastWord = token }
            }
            return pieces.map(Sentence.init(tokens:))
        }

        static func isWordy(_ character: Character) -> Bool { character.isLetter || character.isNumber }
    }

    /// A stretch of speech, as a `speech` segment keeps it: from its first word's start to its last word's end, in
    /// seconds, and its words.
    struct Stretch: Sendable, Equatable {
        let start: Double
        let end: Double
        let text: String
    }

    /// The sentences as stretches of speech, in order: consecutive ones grouped while the stretch stays within `longest`
    /// seconds and `mostWords` words ("$42,000" is one), never across a silence longer than `longestSilence`, between
    /// sentences or inside one (`Sentence.cutAtPauses`). A sentence longer than that by itself is a stretch of its own
    /// (parakeet-mlx is asked to cut sentences at the same limits, `run`). Punctuation before a sentence's first word
    /// ends the stretch before it: parakeet-mlx, cutting at a silence, can hear a sentence's full stop after the
    /// silence, as a sentence of its own.
    static func stretches(of sentences: [Sentence]) -> [Stretch] {
        var stretches: [Stretch] = []
        var open: (start: Double, end: Double, words: Int, text: String)?
        func close() {
            guard let done = open else { return }
            stretches.append(Stretch(start: done.start, end: done.end,
                                     text: done.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        for sentence in sentences.flatMap(\.cutAtPauses) {
            let lead = sentence.tokens.prefix { !$0.isWordy }
            open?.text += lead.map(\.text).joined()
            let said = sentence.tokens.dropFirst(lead.count)
            guard let first = said.first, let last = said.last(where: \.isWordy) else { continue }
            let text = said.map(\.text).joined()
            let words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: Sentence.isWordy) }.count
            if let current = open, first.start - current.end <= longestSilence, last.end - current.start <= longest,
               current.words + words <= mostWords {
                open = (current.start, max(current.end, last.end), current.words + words, current.text + text)
            } else {
                close()
                open = (first.start, last.end, words, text)
            }
        }
        close()
        return stretches
    }

    // MARK: Reading

    /// Reads what's said in a recording (`IndexOptions.speech`): its sentences, in order, none where nothing is said.
    /// Given the recording, a scratch folder, and how long the recording is, in seconds.
    public struct Reader: Sendable {
        let read: @Sendable (_ recording: URL, _ scratch: URL, _ duration: Double) throws -> [Sentence]
    }

    /// Why a recording's speech couldn't be read.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        /// The recording's own failure: ffmpeg, which reads a sound it's known to read (`ffmpegDecodes`), can't decode
        /// it. That's settled until the recording changes. Any other failure is the reader's (parakeet-mlx or ffmpeg
        /// missing, failing or broken, the model not downloaded, the time limit), not a fact about the recording, and the
        /// recording is read again later (`IndexStore.readAgainOnce`).
        var ofRecording = false
    }

    /// parakeet-mlx as the reader, or nil when it or ffmpeg isn't installed. Once it has failed for a reason of its own
    /// (not the recording's, `Failure.ofRecording`), it isn't run again in this process: every recording after would wait
    /// for the same failure (a stuck download for the whole time limit), so each says it at once, and is read again
    /// later.
    public static func parakeetReader() -> Reader? {
        guard let program = parakeet, let ffmpeg else { return nil }
        let broken = BrokenReader()
        return Reader { recording, scratch, duration in
            if let failure = broken.failure { throw failure }
            do {
                let wait = max(shortestWait, duration)
                return try run(program, ffmpeg: ffmpeg, on: recording, in: scratch, timeout: wait)
            } catch let failure as Failure where failure.ofRecording {
                throw failure
            } catch {
                let failure = error as? Failure ?? Failure(description: "parakeet-mlx couldn't read it: \(error)")
                broken.failure = failure
                throw failure
            }
        }
    }

    /// The reader's own failure, once it has failed (`parakeetReader`): the indexer reads one recording at a time, and
    /// prepares the next on another thread.
    private final class BrokenReader: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Failure?

        var failure: Failure? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// How long a reading may take at least, in seconds: the first one downloads the model, which on a slow network takes
    /// a while. A longer recording may take as long as it plays (an M3 Max takes a sixtieth of that).
    static let shortestWait = 1800.0

    /// What parakeet-mlx writes, of which the sentences are read.
    private struct Transcript: Decodable {
        let sentences: [Sentence]
    }

    /// Runs parakeet-mlx on the recording for up to `timeout` seconds, with `model`, its sentences cut at a stretch's
    /// limits (one that runs on is never longer than a stretch). It writes its JSON into a folder of its own in
    /// `scratch`; it says what went wrong on its output and ends with 0 anyway, so a missing JSON is the failure.
    static func run(_ program: String, ffmpeg: String, on recording: URL, in scratch: URL, timeout: Double) throws
        -> [Sentence] {
        let fm = FileManager.default
        let work = scratch.appendingPathComponent("speech-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let output = work.appendingPathComponent("output.txt")
        fm.createFile(atPath: output.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = [recording.path, "--model", model, "--output-format", "json", "--output-dir", work.path,
                             "--output-template", "speech", "--max-words", String(mostWords),
                             "--max-duration", String(longest), "--silence-gap", String(longestSilence)]
        // Without parakeet-mlx's own settings (PARAKEET_MODEL would pick another model, PARAKEET_DECODING another way of
        // decoding): DigUp sets how it reads. It runs ffmpeg by name, and the app's helpers have launchd's PATH, which
        // doesn't hold it.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PARAKEET_") }
        let folder = (ffmpeg as NSString).deletingLastPathComponent
        environment["PATH"] = folder + (environment["PATH"].map { ":" + $0 } ?? "")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let handle = try FileHandle(forWritingTo: output)
        process.standardOutput = handle
        process.standardError = handle
        guard try ran(process, within: timeout) else {
            throw Failure(description: "parakeet-mlx took more than \(Int(timeout / 60)) minutes")
        }
        guard let data = try? Data(contentsOf: work.appendingPathComponent("speech.json")) else {
            // What it said, as one line (it wraps its output at 80 columns when that's a file), without the paragraph
            // it ends with ("… transcription complete. Outputs saved in …").
            let said = ((try? String(contentsOf: output, encoding: .utf8)) ?? "").components(separatedBy: "\n\n")
                .filter { !$0.contains("transcription complete") }.joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // parakeet-mlx says "Failed to load audio" whenever ffmpeg fails (its last error says why): the recording's
            // failure when ffmpeg reads a sound it's known to read, else ffmpeg's own (a library it can't load, say).
            // Anything else is the reader's, and parakeet-mlx's own error says why.
            if said.contains("Failed to load audio") {
                let why = said.range(of: "Error", options: .backwards).map { String(said[$0.lowerBound...]) } ?? said
                let works = ffmpegDecodes(ffmpeg, in: work)
                throw Failure(description: (works ? "ffmpeg couldn't decode it: " : "ffmpeg isn't working: ")
                                  + why.prefix(300), ofRecording: works)
            }
            let why = said.range(of: "Error").map { String(said[$0.lowerBound...]) }
                ?? (said.isEmpty ? "it stopped (\(process.terminationStatus))" : said)
            throw Failure(description: "parakeet-mlx couldn't read it: \(why.prefix(300))")
        }
        return try JSONDecoder().decode(Transcript.self, from: data).sentences
    }

    /// How long ffmpeg may take to decode `ffmpegDecodes`' half second of sound, in seconds.
    static let ffmpegCheck = 30.0

    /// Whether `ffmpeg` decodes a sound it's known to read (half a second of a tone, written here as a WAV) the way
    /// parakeet-mlx has it decode a recording: to 16 kHz mono 16-bit samples.
    static func ffmpegDecodes(_ ffmpeg: String, in work: URL) -> Bool {
        let sample = work.appendingPathComponent("known.wav")
        let rate = AudioExtractor.sampleRate
        let tone = (0..<Int(rate / 2)).map { Int16(8000 * sin(Double($0) * 2 * .pi * 440 / rate)) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-i", sample.path, "-threads", "0", "-f", "s16le", "-ac", "1",
                             "-acodec", "pcm_s16le", "-ar", String(Int(rate)), "-"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try AudioExtractor.writeWAV(tone[...], to: sample)
            return try ran(process, within: ffmpegCheck) && process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Runs `process` for up to `timeout` seconds; false when it was stopped for taking longer.
    private static func ran(_ process: Process, within timeout: Double) throws -> Bool {
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        guard ended.wait(timeout: .now() + timeout) == .timedOut else { return true }
        process.terminate()
        #if !os(Windows)
        if ended.wait(timeout: .now() + 5) == .timedOut { kill(process.processIdentifier, SIGKILL) }
        #endif
        return false
    }
}
