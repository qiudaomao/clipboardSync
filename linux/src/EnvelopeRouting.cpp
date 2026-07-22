#include "EnvelopeRouting.h"

namespace {

constexpr QChar Quote = u'"';
constexpr QChar Backslash = u'\\';
constexpr QChar OpenBrace = u'{';
constexpr QChar CloseBrace = u'}';
constexpr QChar OpenBracket = u'[';
constexpr QChar CloseBracket = u']';
constexpr QChar Colon = u':';
constexpr QChar Comma = u',';

class Scanner {
public:
    explicit Scanner(QStringView json) : json_(json) {}

    bool scan(EnvelopeRouting &out)
    {
        skipWhitespace();
        if (index_ >= json_.size() || json_.at(index_) != OpenBrace)
            return false;
        ++index_;

        while (true) {
            skipWhitespace();
            if (index_ >= json_.size())
                return false;
            if (json_.at(index_) == CloseBrace)
                break;
            if (json_.at(index_) == Comma) {
                ++index_;
                continue;
            }

            qsizetype keyStart = 0;
            qsizetype keyEnd = 0;
            bool keyEscaped = false;
            if (!scanString(keyStart, keyEnd, keyEscaped, true) || keyEscaped)
                return false;
            skipWhitespace();
            if (index_ >= json_.size() || json_.at(index_) != Colon)
                return false;
            ++index_;

            const QStringView key = json_.sliced(keyStart, keyEnd - keyStart);
            const bool isFrom = key == QStringView(u"from");
            const bool isTo = !isFrom && key == QStringView(u"to");
            if (!isFrom && !isTo) {
                if (!skipValue())
                    return false;
                continue;
            }

            skipWhitespace();
            if (index_ >= json_.size())
                return false;
            if (json_.at(index_) != Quote) {
                // `null`, or an unexpected type: no hint, but the envelope is still well-formed.
                if (!skipValue())
                    return false;
                continue;
            }

            qsizetype valueStart = 0;
            qsizetype valueEnd = 0;
            bool valueEscaped = false;
            if (!scanString(valueStart, valueEnd, valueEscaped, true) || valueEscaped)
                return false;
            QString value = json_.sliced(valueStart, valueEnd - valueStart).toString();
            if (isFrom)
                out.from = std::move(value);
            else
                out.to = std::move(value);
        }

        out.valid = true;
        return true;
    }

private:
    void skipWhitespace()
    {
        while (index_ < json_.size()) {
            const QChar current = json_.at(index_);
            if (current != u' ' && current != u'\t' && current != u'\n' && current != u'\r')
                return;
            ++index_;
        }
    }

    /// `json_[index_]` must be the opening quote. Leaves `index_` just past the closing quote and
    /// reports the content bounds.
    ///
    /// Finding the real closing quote costs one QStringView::indexOf (SIMD) plus an O(1) look
    /// backwards: a quote is escaped exactly when an odd number of backslashes immediately precede
    /// it. That matters because the envelope's one large value is ~100 KB of base64 that this has
    /// to step over, and a second forward search for backslashes would double the work.
    ///
    /// `escaped` reports whether the content holds any escape at all, which needs its own bounded
    /// search — so it is only computed when `wantEscaped` is set. Callers that merely skip a value
    /// do not care, and those are exactly the large ones.
    bool scanString(qsizetype &start, qsizetype &end, bool &escaped, bool wantEscaped)
    {
        escaped = false;
        if (index_ >= json_.size() || json_.at(index_) != Quote)
            return false;
        ++index_;
        start = index_;

        qsizetype searchFrom = index_;
        while (true) {
            const qsizetype closing = json_.indexOf(Quote, searchFrom);
            if (closing < 0)
                return false;
            qsizetype runStart = closing;
            while (runStart > start && json_.at(runStart - 1) == Backslash)
                --runStart;
            if (((closing - runStart) & 1) != 0) {
                // Odd run of backslashes: this quote is escaped and does not close the string.
                searchFrom = closing + 1;
                continue;
            }
            end = closing;
            index_ = closing + 1;
            break;
        }

        if (wantEscaped)
            escaped = json_.sliced(start, end - start).indexOf(Backslash) >= 0;
        return true;
    }

    bool skipValue()
    {
        skipWhitespace();
        if (index_ >= json_.size())
            return false;
        const QChar current = json_.at(index_);
        if (current == Quote) {
            qsizetype start = 0;
            qsizetype end = 0;
            bool escaped = false;
            return scanString(start, end, escaped, false);
        }
        if (current == OpenBrace || current == OpenBracket) {
            int depth = 0;
            while (index_ < json_.size()) {
                const QChar at = json_.at(index_);
                if (at == Quote) {
                    qsizetype start = 0;
                    qsizetype end = 0;
                    bool escaped = false;
                    if (!scanString(start, end, escaped, false))
                        return false;
                    continue;
                }
                if (at == OpenBrace || at == OpenBracket) {
                    ++depth;
                } else if (at == CloseBrace || at == CloseBracket) {
                    --depth;
                    if (depth == 0) {
                        ++index_;
                        return true;
                    }
                }
                ++index_;
            }
            return false;
        }
        // Number, true, false, or null: runs until the next structural character.
        while (index_ < json_.size() && json_.at(index_) != Comma && json_.at(index_) != CloseBrace)
            ++index_;
        return true;
    }

    QStringView json_;
    qsizetype index_ = 0;
};

} // namespace

EnvelopeRouting scanEnvelopeRouting(QStringView json)
{
    EnvelopeRouting routing;
    Scanner scanner(json);
    if (!scanner.scan(routing))
        return {};
    return routing;
}
