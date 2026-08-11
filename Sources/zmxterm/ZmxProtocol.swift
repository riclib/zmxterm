import Foundation

/// Wire protocol for zmx's per-session unix socket, mirroring `src/ipc.zig`.
///
/// A frame is `Header{ tag: u8, len: u32 }` — a Zig `packed struct`, little
/// endian — followed by `len` payload bytes. The header is **eight** bytes on
/// the wire, not five; see `ZmxFrame.headerSize` for why, and do not "fix" it.
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

/// `ipc.Info`, everything the daemon knows about its own session.
///
/// Sending `.info` with an empty payload gets one of these back as an `.info`
/// frame. It is how the app reads `task_ended_at` and `task_exit_code` — see
/// `ZmxTaskWatch` for why not out of `zmx list`, which does print them but as
/// text sharing a namespace with the labels.
///
/// ## The wire layout, and how it was derived
///
/// There is no zmx source checkout here and nothing documents this, so it was
/// read off hexdumps of live sessions (zmx 0.7.0, arm64 macOS) by correlating
/// each field against a value already known from `zmx list`, then by running
/// `zmx run` tasks with chosen exit codes and diffing the payload byte by byte.
/// `Info` is a frozen `extern struct`, so it is C layout — natural alignment
/// and tail padding, *not* packed like `Header` is.
///
/// ```text
/// offset  size  field            evidence
///      0     8  clients          usize; 1 for a session `zmx list` calls
///                                clients=1, 2 while a second .Init client was
///                                held open, 0 for an unattached session
///      8     4  pid              i32; matched pid= for six live sessions
///     12     2  command_len      u16; 9 for a session created as `sleep 400`,
///                                0 for every plain shell
///     14     2  start_dir_len    u16; 12 for /private/tmp, 42 for
///                                /Users/riclib/envs/ghostty-control/zmxterm
///     16   256  command          [256]u8, NUL padded
///    272   256  start_dir        [256]u8, NUL padded
///    528     8  created_at       i64 unix seconds; matched created= exactly
///    536     8  task_ended_at    i64 unix seconds, 0 until a task ever ends;
///                                moved to the completion instant on every
///                                `zmx run`, matching the daemon log timestamp
///    544     4  task_exit_code   i32; went 0 → 7 on the first `zmx run` of a
///                                script exiting 7, 0 → 5 for one exiting 5
///    548     4  padding          always zero
///          552  total
/// ```
///
/// The two ambiguities left, neither of which matters in practice: `clients`
/// could be `{ u32 count, u32 unused }` rather than one `usize`, and
/// `task_exit_code` could be an i64 rather than an i32 with tail padding. Bytes
/// 4…7 and 548…551 were zero in every capture, so both readings agree on every
/// value we will ever see. A `usize` plus `i32 pid` plus two `u16` lengths also
/// packs to exactly 16 bytes with no interior padding, which is why that
/// reading is the more likely one.
struct ZmxInfo: Equatable {
    var clients: Int
    var pid: Int32
    var command: String
    var startDirectory: String
    var createdAt: Int64
    /// When the last `zmx run` task finished, or 0 if none ever has.
    var taskEndedAt: Int64
    /// The exit status of a `zmx run` task. **Read the caveats on
    /// `ZmxTaskWatch` before trusting this** — zmx 0.7.0 latches it at the
    /// first task a session ever completes and never updates it again.
    var taskExitCode: Int32

    static let payloadSize = 552

    /// Pure over `Data`, so it is testable from a captured payload literal and
    /// needs no daemon. A payload of the wrong size decodes to `nil` rather
    /// than reading past the end: a future zmx that grows `Info` is a thing to
    /// notice, not to guess at.
    static func decode(_ payload: Data) -> ZmxInfo? {
        guard payload.count == payloadSize else { return nil }
        let bytes = [UInt8](payload)

        func integer<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
            var value = T.zero
            for index in stride(from: MemoryLayout<T>.size - 1, through: 0, by: -1) {
                value = (value << 8) | T(truncatingIfNeeded: bytes[offset + index])
            }
            return value
        }

        /// The buffers are NUL padded *and* carry an explicit length, so use
        /// the length and clamp it. A length longer than its buffer would mean
        /// the layout has moved under us, and truncating is the harmless read.
        func string(at offset: Int, length: Int) -> String {
            let count = min(max(length, 0), 256)
            return String(decoding: bytes[offset ..< offset + count], as: UTF8.self)
        }

        return ZmxInfo(
            clients: Int(integer(UInt64.self, at: 0)),
            pid: integer(Int32.self, at: 8),
            command: string(at: 16, length: Int(integer(UInt16.self, at: 12))),
            startDirectory: string(at: 272, length: Int(integer(UInt16.self, at: 14))),
            createdAt: integer(Int64.self, at: 528),
            taskEndedAt: integer(Int64.self, at: 536),
            taskExitCode: integer(Int32.self, at: 544)
        )
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
