#pragma once

#include <QByteArray>
#include <QString>

/// Binary wire format for the two large-payload sync messages: a clipboard image and a
/// file-transfer chunk. Like `TunnelFrame`, it keeps a big opaque blob off the JSON envelope path —
/// an image or a 1 MiB chunk otherwise pays two base64 passes (payload, then ciphertext), two JSON
/// encodes and a UTF-8 round trip, inflating it ~1.8× on the wire and copying it ~8 times each way.
/// Here the blob travels as raw bytes and only the small metadata (the message minus its blob)
/// stays JSON.
///
/// Text clipboard and every control message keep the JSON envelope: they are small, so there is
/// nothing to save, and leaving them there keeps basic sync on the widely-understood path.
///
/// A binary WebSocket frame's first byte names which codec produced it: `TunnelFrame` frames begin
/// with `1` (its version, which doubles as "type = tunnel"), `BulkFrame` frames begin with `2`. The
/// receive dispatcher switches on that byte, so the two formats never collide.
///
/// Layout (lengths in bytes, no padding):
///
///     0                1   frame type, always 2 (bulk)
///     1                1   format version, currently 1
///     2                1   mode: 1 = AES-GCM encrypted, 2 = HMAC-SHA256 signed plaintext
///     3                1   kind: 1 = clipboard image, 2 = file-transfer chunk
///     4                1   origin device id length
///     5                1   target device id length (0 = broadcast, no target)
///     6                2   metadata length, big-endian
///     8               M    metadata, UTF-8 JSON (the message with its blob field emptied)
///     8+M            L1    origin device id, UTF-8
///     8+M+L1         L2    target device id, UTF-8
///
/// Everything above is the header, `H = 8 + M + L1 + L2` bytes, authenticated but never encrypted,
/// so a relay can route on the target (or broadcast when there is none) without holding the
/// password yet cannot rewrite the metadata or either device id without the receiver noticing.
///
///     mode 1:  H       12   nonce
///              H+12    16   GCM tag
///              H+28     N   ciphertext, with the header as additional authenticated data
///
///     mode 2:  H       32   HMAC-SHA256 over header ‖ payload
///              H+32     N   payload
namespace BulkFrame {

constexpr quint8 FrameType = 2;
constexpr quint8 Version = 1;

enum class Kind : quint8 {
    ClipboardImage = 1,
    FileChunk = 2,
};

struct Decoded {
    Kind kind = Kind::ClipboardImage;
    /// The message JSON with its blob field emptied; the caller re-attaches `payload`.
    QByteArray meta;
    QString origin;
    /// Empty for a broadcast (a clipboard image), non-empty for a targeted message.
    QString target;
    QByteArray payload;
    /// False when the frame was malformed or failed authentication.
    bool valid = false;
};

/// Throws std::runtime_error when a field is out of range or the crypto layer fails.
QByteArray encode(Kind kind, const QByteArray &meta, const QString &origin, const QString &target,
    const QByteArray &payload, const QString &password, bool encrypt);

/// True when `frame` was produced by BulkFrame rather than TunnelFrame.
bool isBulkFrame(const QByteArray &frame);

/// Reads the target device id without the password, so a relay can route a frame it cannot read.
/// Returns "" for a broadcast; the frame being malformed is indistinguishable from a broadcast to a
/// relay, which broadcasts either way.
QString peekTarget(const QByteArray &frame);

/// Never throws: an unreadable or unauthenticated frame comes back with `valid == false`.
Decoded decode(const QByteArray &frame, const QString &password);

} // namespace BulkFrame
