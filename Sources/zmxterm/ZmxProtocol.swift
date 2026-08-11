import Foundation

/// Wire protocol for zmx's per-session unix socket, mirroring `src/ipc.zig`.
///
/// A frame is `Header{ tag: u8, len: u32 }` — a Zig `packed struct`, so five
/// bytes with no padding, little-endian — followed by `len` payload bytes.
///
/// Upstream deliberately keeps `Tag` non-exhaustive (there's a `comptime` guard
/// enforcing it) so old daemons ignore tags they don't know. We do the same:
/// an unrecognised tag decodes to `nil` and its frame is still consumed.
enum ZmxTag: UInt8 {
    case input = 0
    case output = 1
    case resize = 2
    case detach = 3
    case detachAll = 4
    case kill = 5
    case info = 6
    case initialize = 7 // `.Init` upstream; `init` is taken in Swift.
    case history = 8
    case run = 9
    case ack = 10
    case switchSession = 11
    case write = 12
    case taskComplete = 13
    case labelGet = 14
    case labelSet = 15
    case labelClear = 16
    case labelData = 17
    case send = 18
}

/// `ipc.Resize`. Rows precede columns on the wire — easy to get backwards.
struct ZmxResize: Equatable {
    var rows: UInt16
    var cols: UInt16
    var xpixel: UInt16 = 0
    var ypixel: UInt16 = 0

    var payload: Data {
        var data = Data(capacity: 8)
        for value in [rows, cols, xpixel, ypixel] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

struct ZmxMessage {
    /// `nil` for a tag this build doesn't know about.
    let tag: ZmxTag?
    let payload: Data
}

enum ZmxFrame {
    /// `Header` is a Zig `packed struct { tag: u8, len: u32 }` — 40 bits — and
    /// the daemon moves it with `std.mem.asBytes`, which writes `@sizeOf`, not
    /// `@bitSizeOf`. A `u40` rounds up to 8-byte alignment, so three padding
    /// bytes ride along after the length. Sending a tight 5-byte header shifts
    /// every subsequent frame and the daemon decodes nonsense.
    static let headerSize = 8

    static func encode(_ tag: ZmxTag, _ payload: Data = Data()) -> Data {
        var out = Data(capacity: headerSize + payload.count)
        out.append(tag.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: [0, 0, 0])
        out.append(payload)
        return out
    }
}

/// Incremental decoder. Feed whatever the socket hands back; pull whole frames.
///
/// Backed by `[UInt8]` with a read cursor rather than `Data` slices, whose
/// preserved indices make partial-frame bookkeeping a reliable source of bugs.
struct ZmxFrameDecoder {
    private var buffer: [UInt8] = []
    private var cursor = 0

    mutating func feed(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    mutating func next() -> ZmxMessage? {
        guard buffer.count - cursor >= ZmxFrame.headerSize else {
            compact()
            return nil
        }

        let tagByte = buffer[cursor]
        let length = Int(
            UInt32(buffer[cursor + 1])
                | UInt32(buffer[cursor + 2]) << 8
                | UInt32(buffer[cursor + 3]) << 16
                | UInt32(buffer[cursor + 4]) << 24
        )

        let payloadStart = cursor + ZmxFrame.headerSize
        guard buffer.count - payloadStart >= length else {
            compact()
            return nil
        }

        let payload = Data(buffer[payloadStart ..< payloadStart + length])
        cursor = payloadStart + length
        return ZmxMessage(tag: ZmxTag(rawValue: tagByte), payload: payload)
    }

    private mutating func compact() {
        guard cursor > 0 else { return }
        buffer.removeFirst(cursor)
        cursor = 0
    }
}
