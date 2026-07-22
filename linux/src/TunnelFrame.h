#pragma once

#include <QByteArray>
#include <QString>

/// Binary wire format for port-forward `data` frames.
///
/// Every other message on the transport is a JSON envelope, which costs a forwarded TCP chunk two
/// base64 passes (once for the payload, once for the ciphertext), two JSON encodes, and a UTF-8
/// round trip — inflating 60 KB of tunnel traffic to ~107 KB on the wire and copying it eight
/// times. Since `data` frames are the only high-frequency tunnel message, they get their own
/// binary encoding instead; `open` and `close` happen once per connection and stay on the JSON
/// path where they can carry host/port/reason without a bespoke format.
///
/// Layout (lengths in bytes, no padding):
///
///     0                1   version, currently 1
///     1                1   mode: 1 = AES-GCM encrypted, 2 = HMAC-SHA256 signed plaintext
///     2                1   connection id length
///     3                1   origin device id length
///     4                1   target device id length
///     5               L1   connection id, UTF-8
///     5+L1            L2   origin device id, UTF-8
///     5+L1+L2         L3   target device id, UTF-8
///
/// Everything above is the header, `H = 5 + L1 + L2 + L3` bytes. It is authenticated but never
/// encrypted, so a relay can route on the target without holding the password, yet cannot rewrite
/// the connection id or either device id without the receiver noticing.
///
///     mode 1:  H       12   nonce
///              H+12    16   GCM tag
///              H+28     N   ciphertext, with the header as additional authenticated data
///
///     mode 2:  H       32   HMAC-SHA256 over header ‖ payload
///              H+32     N   payload
///
/// Device ids are not a fixed width — macOS stores a 36-character UUID string while Windows and
/// Linux store 32 hex characters — hence the length prefixes rather than raw 16-byte UUIDs.
namespace TunnelFrame {

constexpr quint8 Version = 1;

struct Decoded {
    QString connectionId;
    QString origin;
    QString target;
    QByteArray payload;
    /// False when the frame was malformed or failed authentication.
    bool valid = false;
};

/// Throws std::runtime_error when an identifier is out of range or the crypto layer fails.
QByteArray encode(const QString &connectionId, const QString &origin, const QString &target,
    const QByteArray &payload, const QString &password, bool encrypt);

/// Reads the target device id without the password, so a relay can route a frame it cannot read.
/// Returns an empty string for anything malformed; callers fall back to broadcasting.
QString peekTarget(const QByteArray &frame);

/// Never throws: an unreadable or unauthenticated frame comes back with `valid == false`.
Decoded decode(const QByteArray &frame, const QString &password);

} // namespace TunnelFrame
