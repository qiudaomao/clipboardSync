#include "EnvelopeRouting.h"

#include <QCoreApplication>
#include <QDebug>
#include <QElapsedTimer>
#include <QJsonDocument>
#include <QJsonObject>

namespace {

int failures = 0;

void check(const char *name, QStringView json, const QString &expectFrom, const QString &expectTo)
{
    const EnvelopeRouting routing = scanEnvelopeRouting(json);
    if (!routing.valid || routing.from != expectFrom || routing.to != expectTo) {
        qWarning() << "FAIL" << name << "valid" << routing.valid
                   << "from" << routing.from << "want" << expectFrom
                   << "to" << routing.to << "want" << expectTo;
        ++failures;
    }
}

void checkInvalid(const char *name, QStringView json)
{
    const EnvelopeRouting routing = scanEnvelopeRouting(json);
    if (routing.valid) {
        qWarning() << "FAIL" << name << "expected invalid, got from" << routing.from << "to" << routing.to;
        ++failures;
    }
}

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);

    // Qt's QJsonObject sorts keys alphabetically, so the large ciphertext lands first and `to`
    // lands late; Swift and .NET use declaration order, which puts both hints last. Both must work.
    check("qt order",
        uR"({"ciphertext":"QUFB","from":"dev-a","nonce":"bm8=","salt":"c2E=","tag":"dGc=","to":"dev-b","type":"encrypted","version":2})",
        QStringLiteral("dev-a"), QStringLiteral("dev-b"));
    check("declaration order",
        uR"({"type":"encrypted","version":2,"salt":"c2E=","nonce":"bm8=","ciphertext":"QUFB","tag":"dGc=","from":"dev-a","to":"dev-b"})",
        QStringLiteral("dev-a"), QStringLiteral("dev-b"));
    check("broadcast has no to",
        uR"({"type":"signed","version":1,"payload":"eHg=","mac":"bQ==","from":"dev-a"})",
        QStringLiteral("dev-a"), QString());
    check("explicit nulls",
        uR"({"type":"encrypted","from":null,"to":null,"ciphertext":"QQ=="})",
        QString(), QString());
    // Base64 never contains a quote, but it does contain '+' and '/'; make sure a value that looks
    // structural does not confuse the walker.
    check("payload containing braces and commas",
        uR"({"ciphertext":"e30sey8rfQ==","from":"a","to":"b"})",
        QStringLiteral("a"), QStringLiteral("b"));
    check("escaped quote inside a skipped value",
        uR"({"note":"he said \"hi\", then {left}","from":"a","to":"b"})",
        QStringLiteral("a"), QStringLiteral("b"));
    check("nested object skipped",
        uR"({"meta":{"a":[1,2,{"b":"}"}],"c":"x"},"from":"a","to":"b"})",
        QStringLiteral("a"), QStringLiteral("b"));
    check("whitespace",
        uR"({ "from" : "a" , "to" : "b" })",
        QStringLiteral("a"), QStringLiteral("b"));
    check("empty to",
        uR"({"from":"a","to":""})", QStringLiteral("a"), QString());
    check("no routing hints at all",
        uR"({"type":"encrypted","ciphertext":"QQ=="})", QString(), QString());
    // A key must match exactly, and nested from/to must not leak into the top-level result.
    check("similar and nested key names",
        uR"({"auto":"x","tot":"y","payload":{"from":"nested","to":"nested"},"from":"a"})",
        QStringLiteral("a"), QString());

    checkInvalid("not an object", u"[1,2,3]");
    checkInvalid("truncated", uR"({"from":"a","to":)");
    checkInvalid("empty", u"");
    // Escapes in a routing value bail out so the caller falls back to the full parser.
    checkInvalid("escaped routing value", uR"({"from":"a\/b","to":"c"})");

    // The scanner exists to beat QJsonDocument on relay frames, so hold it to that.
    QString frame = QStringLiteral(R"({"type":"encrypted","version":2,"salt":"c2E=","nonce":"bm8=","ciphertext":")");
    frame += QString(QStringLiteral("QUJDRA")).repeated(107000 / 6);
    frame += QStringLiteral(R"(","tag":"dGc=","from":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","to":"5A1B2C3D-4F89-11D3-9A0C-0305E82C3301"})");

    const EnvelopeRouting large = scanEnvelopeRouting(frame);
    if (!large.valid || large.to != QStringLiteral("5A1B2C3D-4F89-11D3-9A0C-0305E82C3301")) {
        qWarning() << "FAIL large frame:" << large.valid << large.from << large.to;
        ++failures;
    }

    constexpr int iterations = 500;
    QElapsedTimer timer;
    timer.start();
    for (int i = 0; i < iterations; ++i)
        (void)scanEnvelopeRouting(frame);
    const qint64 scanNs = timer.nsecsElapsed();

    timer.restart();
    for (int i = 0; i < iterations; ++i) {
        const QJsonObject envelope = QJsonDocument::fromJson(frame.toUtf8()).object();
        (void)envelope.value(QStringLiteral("to")).toString();
    }
    const qint64 parseNs = timer.nsecsElapsed();

    qInfo("frame %lld chars: scan %.1f us/frame, QJsonDocument %.1f us/frame (%.1fx)",
        static_cast<long long>(frame.size()),
        scanNs / 1000.0 / iterations, parseNs / 1000.0 / iterations,
        static_cast<double>(parseNs) / static_cast<double>(scanNs));
    if (scanNs >= parseNs) {
        qWarning() << "FAIL scanner is not faster than QJsonDocument";
        ++failures;
    }

    if (failures > 0) {
        qWarning() << failures << "failures";
        return 1;
    }
    qInfo("all envelope routing tests passed");
    return 0;
}
