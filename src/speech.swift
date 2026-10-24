// Live transcription with SpeechAnalyzer/SpeechTranscriber (macOS 26+), which is more accurate
// than SFSpeechRecognizer and has no per-request time limit. Lives in the Swift dylib next to the
// enhancer; shim.m feeds it microphone buffers and falls back to SFSpeechRecognizer when this
// isn't ready (model not installed yet, unsupported language).
import AVFoundation
import Foundation
import Speech

public typealias TextCallback = @convention(c) (UnsafePointer<CChar>, Bool, Int) -> Void

private final class Session: @unchecked Sendable {
    let id: Int
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let format: AVAudioFormat
    var converter: AVAudioConverter?
    let onText: TextCallback
    var tasks: [Task<Void, Never>] = []

    init(id: Int, transcriber: SpeechTranscriber, format: AVAudioFormat, onText: @escaping TextCallback) {
        self.id = id
        self.transcriber = transcriber
        self.format = format
        self.onText = onText
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        continuation = cont
        let analyzer = self.analyzer
        tasks.append(Task { try? await analyzer.start(inputSequence: stream) })
    }

    func emit(_ text: String, final: Bool) {
        DispatchQueue.main.async { [onText, id] in text.withCString { onText($0, final, id) } }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    func collectResults() {
        let transcriber = self.transcriber
        tasks.append(Task { [self] in
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        finalized += piece
                        emit(finalized, final: false)
                    } else {
                        emit(finalized + piece, final: false)
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("speech results failed: \(error)\n".utf8))
            }
            emit(finalized.trimmingCharacters(in: .whitespaces), final: true)
        })
    }
}

private enum Engine {
    nonisolated(unsafe) static var format: AVAudioFormat?
    nonisolated(unsafe) static var locale: Locale?
    nonisolated(unsafe) static var ready = false
    nonisolated(unsafe) static var session: Session?
    nonisolated(unsafe) static var nextID = 0
}

/// Checks the language model and downloads it if needed. Call once at launch; `sa_sx_ready` turns true when usable.
@_cdecl("sa_sx_prepare")
public func saSxPrepare() {
    Task {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return }
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                FileHandle.standardError.write(Data("downloading speech model for \(locale.identifier)…\n".utf8))
                try await request.downloadAndInstall()
            }
            Engine.format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
            Engine.locale = locale
            Engine.ready = Engine.format != nil
            FileHandle.standardError.write(Data("speech analyzer ready (\(locale.identifier))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("speech analyzer unavailable: \(error)\n".utf8))
        }
    }
}

@_cdecl("sa_sx_ready")
public func saSxReady() -> Bool { Engine.ready }

/// Starts a session; returns its id (> 0), or 0 if not ready. `vocabulary` is newline-separated terms.
@_cdecl("sa_sx_start")
public func saSxStart(_ vocabulary: UnsafePointer<CChar>?, _ onText: TextCallback) -> Int {
    guard Engine.ready, let locale = Engine.locale, let format = Engine.format else { return 0 }
    Engine.nextID += 1
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    let session = Session(id: Engine.nextID, transcriber: transcriber, format: format, onText: onText)
    session.collectResults()
    if let vocabulary {
        let terms = String(cString: vocabulary).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        if !terms.isEmpty {
            let analyzer = session.analyzer
            Task {
                let context = AnalysisContext()
                context.contextualStrings[.general] = terms
                try? await analyzer.setContext(context)
            }
        }
    }
    Engine.session = session
    return session.id
}

/// Feeds one microphone buffer (an AVAudioPCMBuffer passed as an unretained pointer).
@_cdecl("sa_sx_append")
public func saSxAppend(_ buffer: UnsafeRawPointer) {
    guard let session = Engine.session else { return }
    session.append(Unmanaged<AVAudioPCMBuffer>.fromOpaque(buffer).takeUnretainedValue())
}

/// Ends the audio; the final text arrives through the callback with `final = true`.
@_cdecl("sa_sx_finish")
public func saSxFinish() {
    guard let session = Engine.session else { return }
    Engine.session = nil
    session.continuation.finish()
    let analyzer = session.analyzer
    Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
}
