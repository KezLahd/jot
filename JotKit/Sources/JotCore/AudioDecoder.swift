import AVFoundation

/// Decodes any audio or video file AVFoundation can open (including fragmented MP4 and HE-AAC from Instagram)
/// into 16 kHz mono Float32 samples, which is what Whisper wants.
public enum AudioDecoder {
    public static let sampleRate: Double = 16_000

    public static func samples(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do { tracks = try await asset.loadTracks(withMediaType: .audio) } catch { throw JotError.decodeFailed(error.localizedDescription) }
        guard let track = tracks.first else { throw JotError.noAudio }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw JotError.decodeFailed(error.localizedDescription) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw JotError.decodeFailed("can't read this audio track") }
        reader.add(output)
        guard reader.startReading() else { throw JotError.decodeFailed(reader.error?.localizedDescription ?? "can't start reading") }

        var out: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let start = out.count
            out.append(contentsOf: repeatElement(0, count: length / MemoryLayout<Float>.size))
            out.withUnsafeMutableBytes { dst in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: dst.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        if reader.status == .failed { throw JotError.decodeFailed(reader.error?.localizedDescription ?? "read failed") }
        guard !out.isEmpty else { throw JotError.noAudio }
        return out
    }
}
