//
//  UtteranceDump.swift
//  MaryVoice
//
//  WHAT: Opt-in record of exactly what the transcriber heard — WAV + JSON per utterance.
//  IN:   VoicePipeline (open / append / close), VoicePipelineConfig.utteranceDumpDirectory
//  OUT:  <dir>/<stamp>.wav + <stamp>.json — replay with `mary-voice-probe stt-file`
//  PIN:  Off unless a directory is configured. Files are written off the pipeline actor.
//

import AVFoundation
import Foundation
import os

final class UtteranceDump {

    struct Record: Codable, Sendable {
        let backend: String
        let openedAt: Date
        /// nil when the transcriber heard nothing it would commit to.
        let transcript: String?
        /// `begin` latency — cold work on the speech-start frame.
        let beginSeconds: Double
        /// `finish` latency — past the transcriber's grace means it fell back.
        let finishSeconds: Double
        let audioSeconds: Double
        let sampleRate: Double
    }

    private struct Payload: @unchecked Sendable {
        let buffers: [AVAudioPCMBuffer]
    }

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "voice.dump")
    private static let writeQueue = DispatchQueue(label: "mary.voice.dump", qos: .utility)

    private let directory: URL
    private let backend: STTBackend
    private var buffers: [AVAudioPCMBuffer] = []
    private var openedAt: Date?
    private var beginSeconds: TimeInterval = 0

    init(directory: URL, backend: STTBackend) {
        self.directory = directory
        self.backend = backend
    }

    func open(beginSeconds: TimeInterval) {
        buffers = []
        openedAt = Date()
        self.beginSeconds = beginSeconds
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard openedAt != nil else { return }
        buffers.append(buffer)
    }

    /// Drop the utterance without writing (noise, barge-in, stop).
    func abandon() {
        buffers = []
        openedAt = nil
    }

    func close(transcript: String?, finishSeconds: TimeInterval) {
        guard let openedAt, let format = buffers.first?.format else {
            abandon()
            return
        }
        // A mid-utterance route change can switch formats; the file keeps the first.
        let kept = buffers.filter { $0.format == format }
        let frames = kept.reduce(0) { $0 + Double($1.frameLength) }
        let record = Record(
            backend: backend.rawValue,
            openedAt: openedAt,
            transcript: transcript,
            beginSeconds: beginSeconds,
            finishSeconds: finishSeconds,
            audioSeconds: frames / format.sampleRate,
            sampleRate: format.sampleRate)
        let payload = Payload(buffers: kept)
        let directory = directory
        abandon()
        Self.writeQueue.async {
            Self.write(payload.buffers, record: record, to: directory)
        }
    }

    private static func write(_ buffers: [AVAudioPCMBuffer], record: Record, to directory: URL) {
        guard let format = buffers.first?.format else { return }
        let stampFormatter = DateFormatter()
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = stampFormatter.string(from: record.openedAt)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
            ]
            let file = try AVAudioFile(
                forWriting: directory.appendingPathComponent("\(stamp).wav"),
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
            for buffer in buffers { try file.write(from: buffer) }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record)
                .write(to: directory.appendingPathComponent("\(stamp).json"))
        } catch {
            log.error("utterance dump failed: \(error.localizedDescription)")
        }
    }
}
