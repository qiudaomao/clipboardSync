#pragma once

#include <QString>
#include <QStringView>

/// The plaintext routing hints of a sync envelope: `from` names the sending device, `to` the
/// intended receiver (absent on broadcasts). A relay reads these to forward a message without
/// being able to decrypt it.
struct EnvelopeRouting {
    QString from;
    QString to;
    /// False when the input was not a well-formed JSON object, or when a key or routing value
    /// carried a backslash escape. Callers treat that as "no routing hint" and fall back to
    /// broadcasting, which the receiver-side target filter makes harmless.
    bool valid = false;
};

/// Pulls `from`/`to` out of an envelope without parsing it.
///
/// `QJsonDocument::fromJson` has to unescape and allocate the envelope's `ciphertext` (or
/// `payload`) string, which for a port-forward or file chunk is ~100 KB of base64 that a relay
/// immediately discards. This walks the top level instead, stepping over string values without
/// copying them, and materialises only the two short device ids.
///
/// Key order is not assumed: the three clients emit these keys in different positions (Qt's
/// QJsonObject sorts alphabetically, Swift and .NET use declaration order), so the routing hints
/// can sit either side of the large value.
EnvelopeRouting scanEnvelopeRouting(QStringView json);
