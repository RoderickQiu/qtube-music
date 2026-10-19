import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

// Native engine — decoding audio that lives in memory. A track's whole AAC file (3–14 MB) is held as `Data` and never
// touches the disk (docs/native-engine-spike.md §7.6: a file cache would be a download in the ToS sense).
//
// AudioToolbox opens it through read callbacks (`AudioFileOpenWithCallbacks`, YouTube's fragmented MP4 = 'mp4f'), and
// ExtAudioFile decodes it to the engine's one PCM format (Float32, deinterleaved, stereo, `sampleRate`), resampling
// if needed. ExtAudioFile honours the file's edit list: the 2,112 AAC priming frames and the remainder are trimmed,
// so tracks join sample-exactly (the gapless seam).

/// The compressed bytes of one track, owned for as long as a decoder reads them.
final class QTNativeAudioBytes: @unchecked Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
}

/// One track, decoded on demand from memory. Not thread-safe: one owner (the deck's queue) reads it at a time.
final class QTNativeMemoryAudioFile: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case open(OSStatus), wrap(OSStatus), property(OSStatus), read(OSStatus), seek(OSStatus)
        var description: String {
            switch self {
            case .open(let s): "AudioFileOpenWithCallbacks \(s)"
            case .wrap(let s): "ExtAudioFileWrapAudioFileID \(s)"
            case .property(let s): "ExtAudioFile property \(s)"
            case .read(let s): "ExtAudioFileRead \(s)"
            case .seek(let s): "ExtAudioFileSeek \(s)"
            }
        }
    }

    /// The PCM format every decoder produces; the engine's graph runs in it.
    static func processingFormat(sampleRate: Double) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    }

    let bytes: QTNativeAudioBytes
    let format: AVAudioFormat
    /// The file's own sample rate.
    let fileSampleRate: Double
    /// Decoded length in `format` frames (priming and remainder trimmed).
    let length: AVAudioFramePosition
    /// Next frame `read` returns, in `format` frames.
    private(set) var position: AVAudioFramePosition = 0

    private var fileID: AudioFileID?
    private var ext: ExtAudioFileRef?
    private let box: Unmanaged<QTNativeAudioBytes>

    var duration: TimeInterval { Double(length) / format.sampleRate }

    init(bytes: QTNativeAudioBytes, sampleRate: Double = 44_100) throws {
        self.bytes = bytes
        self.format = Self.processingFormat(sampleRate: sampleRate)
        box = Unmanaged.passRetained(bytes)
        var fid: AudioFileID?
        var status = AudioFileOpenWithCallbacks(box.toOpaque(), Self.readProc, nil, Self.sizeProc, nil,
                                                kAudioFileMPEG4Type, &fid)
        guard status == noErr, let fid else { box.release(); throw Failure.open(status) }
        fileID = fid
        var ref: ExtAudioFileRef?
        status = ExtAudioFileWrapAudioFileID(fid, false, &ref)
        guard status == noErr, let ref else { AudioFileClose(fid); box.release(); throw Failure.wrap(status) }
        ext = ref

        var fileFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileDataFormat, &size, &fileFormat)
        guard status == noErr else { Self.close(ref, fid, box); throw Failure.property(status) }
        fileSampleRate = fileFormat.mSampleRate > 0 ? fileFormat.mSampleRate : sampleRate

        var client = format.streamDescription.pointee
        status = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else { Self.close(ref, fid, box); throw Failure.property(status) }

        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        status = ExtAudioFileGetProperty(ref, kExtAudioFileProperty_FileLengthFrames, &size, &frames)
        guard status == noErr else { Self.close(ref, fid, box); throw Failure.property(status) }
        length = AVAudioFramePosition((Double(frames) * sampleRate / fileSampleRate).rounded(.down))
    }

    deinit {
        if let ext, let fileID { Self.close(ext, fileID, box) }
    }

    private static func close(_ ext: ExtAudioFileRef, _ fid: AudioFileID, _ box: Unmanaged<QTNativeAudioBytes>) {
        ExtAudioFileDispose(ext)
        AudioFileClose(fid)
        box.release()
    }

    /// Moves the read position (in `format` frames).
    func seek(to frame: AVAudioFramePosition) throws {
        guard let ext else { return }
        let clamped = max(0, min(frame, length))
        // ExtAudioFileSeek takes the file's frames, not the client format's.
        let fileFrame = Int64((Double(clamped) * fileSampleRate / format.sampleRate).rounded(.down))
        let status = ExtAudioFileSeek(ext, fileFrame)
        guard status == noErr else { throw Failure.seek(status) }
        position = clamped
    }

    /// Decodes up to `buffer.frameCapacity` frames into `buffer` (sets `frameLength`); 0 = end of file.
    @discardableResult
    func read(into buffer: AVAudioPCMBuffer) throws -> AVAudioFrameCount {
        guard let ext else { buffer.frameLength = 0; return 0 }
        var frames = UInt32(buffer.frameCapacity)
        buffer.frameLength = buffer.frameCapacity
        let status = ExtAudioFileRead(ext, &frames, buffer.mutableAudioBufferList)
        guard status == noErr else { buffer.frameLength = 0; throw Failure.read(status) }
        buffer.frameLength = frames
        position += AVAudioFramePosition(frames)
        return frames
    }

    // MARK: AudioFile callbacks (any thread; the bytes never change)

    private static let readProc: AudioFile_ReadProc = { client, position, requestCount, buffer, actualCount in
        let bytes = Unmanaged<QTNativeAudioBytes>.fromOpaque(client).takeUnretainedValue()
        let count = Int64(bytes.data.count)
        guard position >= 0, position < count else {
            actualCount.pointee = 0
            return position == count ? noErr : OSStatus(kAudioFileEndOfFileError)
        }
        let n = Int(min(Int64(requestCount), count - position))
        bytes.data.withUnsafeBytes { raw in
            buffer.copyMemory(from: raw.baseAddress!.advanced(by: Int(position)), byteCount: n)
        }
        actualCount.pointee = UInt32(n)
        return noErr
    }

    private static let sizeProc: AudioFile_GetSizeProc = { client in
        Int64(Unmanaged<QTNativeAudioBytes>.fromOpaque(client).takeUnretainedValue().data.count)
    }
}
