using System;

namespace ClipboardSyncWin;

/// Just the routing hints of an encrypted envelope, for relays that must not (and cannot) decrypt.
internal sealed class EnvelopeRouting
{
    public string? From { get; set; }
    public string? To { get; set; }

    /// Pulls From/To out of an envelope without parsing it.
    ///
    /// A JsonSerializer pass has to unescape and allocate the envelope's Ciphertext (or Payload)
    /// string, which for a file chunk is ~100 KB of base64 that a relay immediately discards. This
    /// walks the top level instead, stepping over string values without copying them, and
    /// materializes only the two short device ids.
    ///
    /// Key order is not assumed: the three clients emit these keys in different positions
    /// (JsonSerializer and Swift use declaration order, Qt's QJsonObject sorts alphabetically), so
    /// the routing hints can sit either side of the large value.
    ///
    /// Returns null when the input isn't a JSON object or escapes appear in a key or in a routing
    /// value - device ids are UUIDs, so that does not happen in practice. Callers treat null as
    /// "no routing hint", which degrades to the pre-existing broadcast fallback.
    public static EnvelopeRouting? Scan(string message)
    {
        var span = message.AsSpan();
        var index = 0;
        SkipWhitespace(span, ref index);
        if (index >= span.Length || span[index] != '{')
        {
            return null;
        }
        index++;

        string? from = null;
        string? to = null;
        while (true)
        {
            SkipWhitespace(span, ref index);
            if (index >= span.Length)
            {
                return null;
            }
            if (span[index] == '}')
            {
                break;
            }
            if (span[index] == ',')
            {
                index++;
                continue;
            }

            if (!ScanString(span, ref index, out var key, out var keyEscaped, true) || keyEscaped)
            {
                return null;
            }
            SkipWhitespace(span, ref index);
            if (index >= span.Length || span[index] != ':')
            {
                return null;
            }
            index++;

            var isFrom = span[key].SequenceEqual("from");
            var isTo = !isFrom && span[key].SequenceEqual("to");
            if (!isFrom && !isTo)
            {
                if (!SkipValue(span, ref index))
                {
                    return null;
                }
                continue;
            }

            SkipWhitespace(span, ref index);
            if (index >= span.Length)
            {
                return null;
            }
            if (span[index] != '"')
            {
                // null, or an unexpected type: no hint, but the envelope is still well-formed.
                if (!SkipValue(span, ref index))
                {
                    return null;
                }
                continue;
            }
            if (!ScanString(span, ref index, out var value, out var valueEscaped, true) || valueEscaped)
            {
                return null;
            }
            if (isFrom)
            {
                from = new string(span[value]);
            }
            else
            {
                to = new string(span[value]);
            }
        }

        return new EnvelopeRouting { From = from, To = to };
    }

    private static void SkipWhitespace(ReadOnlySpan<char> span, ref int index)
    {
        while (index < span.Length && span[index] is ' ' or '\t' or '\n' or '\r')
        {
            index++;
        }
    }

    /// span[index] must be the opening quote. Leaves index just past the closing quote and reports
    /// the content range.
    ///
    /// Finding the real closing quote costs one vectorized IndexOf plus an O(1) look backwards: a
    /// quote is escaped exactly when an odd number of backslashes immediately precede it. That
    /// matters because the envelope's one large value is ~100 KB of base64 this has to step over,
    /// and a second forward search for backslashes would double the work.
    ///
    /// escaped reports whether the content holds any escape at all, which needs its own bounded
    /// search - so it is only computed when wantEscaped is set. Callers that merely skip a value do
    /// not care, and those are exactly the large ones.
    private static bool ScanString(
        ReadOnlySpan<char> span,
        ref int index,
        out Range content,
        out bool escaped,
        bool wantEscaped)
    {
        content = default;
        escaped = false;
        if (index >= span.Length || span[index] != '"')
        {
            return false;
        }
        index++;
        var start = index;

        var searchFrom = index;
        int end;
        while (true)
        {
            var hit = span[searchFrom..].IndexOf('"');
            if (hit < 0)
            {
                return false;
            }
            var closing = searchFrom + hit;
            var runStart = closing;
            while (runStart > start && span[runStart - 1] == '\\')
            {
                runStart--;
            }
            if (((closing - runStart) & 1) != 0)
            {
                // Odd run of backslashes: this quote is escaped and does not close the string.
                searchFrom = closing + 1;
                continue;
            }
            end = closing;
            index = closing + 1;
            break;
        }

        content = start..end;
        if (wantEscaped)
        {
            escaped = span[start..end].IndexOf('\\') >= 0;
        }
        return true;
    }

    private static bool SkipValue(ReadOnlySpan<char> span, ref int index)
    {
        SkipWhitespace(span, ref index);
        if (index >= span.Length)
        {
            return false;
        }
        switch (span[index])
        {
            case '"':
                return ScanString(span, ref index, out _, out _, false);
            case '{':
            case '[':
            {
                var depth = 0;
                while (index < span.Length)
                {
                    var current = span[index];
                    if (current == '"')
                    {
                        if (!ScanString(span, ref index, out _, out _, false))
                        {
                            return false;
                        }
                        continue;
                    }
                    if (current is '{' or '[')
                    {
                        depth++;
                    }
                    else if (current is '}' or ']')
                    {
                        depth--;
                        if (depth == 0)
                        {
                            index++;
                            return true;
                        }
                    }
                    index++;
                }
                return false;
            }
            default:
                // Number, true, false, or null: runs until the next structural character.
                while (index < span.Length && span[index] != ',' && span[index] != '}')
                {
                    index++;
                }
                return true;
        }
    }
}
