import AVFoundation
import Foundation

/// A small visual envelope of the *original* source media. This is read-only: it never
/// exports audio, opens the processed '-cut' file, or modifies the episode's media.
struct SponsorWaveformData: Sendable {
    var duration: Double
    var levels: [Double]
}

enum SponsorWaveformLoader {
    enum Failure: LocalizedError {
        case missingSource, noAudio, unableToDecode

        var errorDescription: String? {
            switch self {
            case .missingSource: "The original audio file is not available on this Mac."
            case .noAudio: "The source file does not contain an audio track."
            case .unableToDecode: "The audio waveform could not be decoded. You can still edit cut times manually."
            }
        }
    }

    /// Streaming decode at a low sample rate, performed from a detached utility task by
    /// the caller. Memory is bounded by one AVFoundation sample buffer and the fixed bins.
    static func load(from url: URL, bins: Int? = nil) async throws -> SponsorWaveformData {
        guard url.isFileURL, FileManager.default.isReadableFile(atPath: url.path) else {
            throw Failure.missingSource
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.noAudio
        }
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw Failure.unableToDecode }
        // Keep roughly 12 envelopes per second so zoomed-in edits retain detail on a
        // two-hour podcast while the buffer stays under ~1 MB even for long recordings.
        let bucketCount = min(120_000, max(128, bins ?? Int(min(120_000, seconds * 12))))
        var levels = [Double](repeating: 0, count: bucketCount)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 11_025
        ])
        guard reader.canAdd(output) else { throw Failure.unableToDecode }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.unableToDecode }

        do {
            while reader.status == .reading {
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var available = 0
                var total = 0
                var pointer: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &available,
                                                  totalLengthOut: &total, dataPointerOut: &pointer) == noErr,
                      let pointer else { continue }

                // A block buffer is not guaranteed contiguous; only examine the bytes
                // which CoreMedia actually returned at this pointer.
                let number = min(CMSampleBufferGetNumSamples(sample), available / MemoryLayout<Float>.size)
                guard number > 0 else { continue }
                let format = CMSampleBufferGetFormatDescription(sample)
                let sampleRate = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 11_025
                guard sampleRate.isFinite, sampleRate > 0 else { continue }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard timestamp.isFinite else { continue }
                let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)

                // At 11 kHz, every eighth sample still yields ~1,375 observations/second.
                // This avoids doing millions of redundant peak calculations on the main actor.
                for index in stride(from: 0, to: number, by: 8) {
                    let value = abs(Double(samples[index]))
                    guard value.isFinite else { continue }
                    let time = timestamp + Double(index) / sampleRate
                    let bucket = Int((max(0, min(seconds, time)) / seconds * Double(bucketCount - 1)).rounded(.down))
                    levels[bucket] = max(levels[bucket], min(1, value))
                }
            }
            try Task.checkCancellation()
            guard reader.status == .completed else { throw reader.error ?? Failure.unableToDecode }
        } catch {
            reader.cancelReading()
            throw error
        }

        let tallest = levels.max() ?? 0
        if tallest > 0.0001 {
            let original = levels
            for index in levels.indices {
                // Perceptual scaling keeps quieter speech visible next to louder ad segments.
                let left = original[max(0, index - 1)]
                let right = original[min(original.count - 1, index + 1)]
                let envelope = max(original[index], max(left, right) * 0.40)
                levels[index] = min(1, sqrt(envelope / tallest))
            }
        }
        return SponsorWaveformData(duration: seconds, levels: levels)
    }
}
