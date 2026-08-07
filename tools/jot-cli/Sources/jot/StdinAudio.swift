import Foundation

enum PCMEncoding: String {
    case s16le
    case f32le

    var bytesPerFrame: Int {
        switch self {
        case .s16le: return 2
        case .f32le: return 4
        }
    }
}

/// Reads raw 16 kHz mono PCM from stdin on a dedicated blocking thread and
/// yields decoded Float chunks into an `AsyncStream` (the same
/// producer/consumer shape the app's streaming transcribers use). A leading
/// RIFF/WAV header is autodetected and skipped — the `--encoding` flag, not
/// the WAV `fmt` chunk, governs sample decoding (documented in the man page).
///
/// The stream finishes on stdin EOF. The trailing partial frame (if the
/// producer was cut mid-sample) is dropped.
struct StdinAudioReader {
    let encoding: PCMEncoding

    func chunks() -> AsyncStream<[Float]> {
        let encoding = self.encoding
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let thread = Thread {
                var pending = Data()
                var headerHandled = false
                let stdin = FileHandle.standardInput

                while true {
                    let data = stdin.availableData  // blocks; empty ⇒ EOF
                    if data.isEmpty { break }
                    pending.append(data)

                    if !headerHandled {
                        // Need at least the RIFF magic to sniff.
                        if pending.count < 12 { continue }
                        if pending.prefix(4).elementsEqual("RIFF".utf8) {
                            guard let offset = Self.wavDataOffset(pending) else {
                                // `data` chunk header not fully buffered yet.
                                // A malformed "RIFF" prefix that never yields a
                                // data chunk is bounded by the 1 MiB guard.
                                if pending.count > 1_048_576 {
                                    FileHandle.standardError.write(
                                        Data("jot: error: RIFF header with no data chunk in first 1 MiB\n".utf8))
                                    exit(1)
                                }
                                continue
                            }
                            pending.removeFirst(offset)
                        }
                        headerHandled = true
                    }

                    let samples = Self.consumeFrames(&pending, encoding: encoding)
                    if !samples.isEmpty { continuation.yield(samples) }
                }

                if headerHandled {
                    let tail = Self.consumeFrames(&pending, encoding: encoding)
                    if !tail.isEmpty { continuation.yield(tail) }
                }
                continuation.finish()
            }
            thread.name = "jot.stdin-audio"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Decode every complete frame out of `data`, leaving a partial trailing
    /// frame in place for the next read.
    private static func consumeFrames(_ data: inout Data, encoding: PCMEncoding) -> [Float] {
        let stride = encoding.bytesPerFrame
        let frameCount = data.count / stride
        guard frameCount > 0 else { return [] }

        var out = [Float]()
        out.reserveCapacity(frameCount)
        data.prefix(frameCount * stride).withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            switch encoding {
            case .s16le:
                for i in 0..<frameCount {
                    let v = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                    out.append(Float(Int16(bitPattern: v)) / 32768.0)
                }
            case .f32le:
                for i in 0..<frameCount {
                    let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
                    out.append(Float(bitPattern: bits))
                }
            }
        }
        data.removeFirst(frameCount * stride)
        return out
    }

    /// Minimal RIFF walk: returns the offset of the first audio byte (just
    /// past the `data` chunk header), or `nil` if the chunk list isn't fully
    /// buffered yet.
    private static func wavDataOffset(_ data: Data) -> Int? {
        var offset = 12  // "RIFF" + size + "WAVE"
        while offset + 8 <= data.count {
            let id = data.subdata(in: offset..<(offset + 4))
            let size = data.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            }
            if id.elementsEqual("data".utf8) {
                return offset + 8
            }
            // Chunks are word-aligned: odd sizes carry a pad byte.
            offset += 8 + Int(size) + (Int(size) & 1)
        }
        return nil
    }
}
