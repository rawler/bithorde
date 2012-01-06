#include "magneturi.h"

#include <QStringList>

#include "hashes.h"

const static QString MAGNET_PREFIX = "magnet:?";

#include <QTextStream>

ExactIdentifier ExactIdentifier::fromUrlEnc(QString enc)
{
    ExactIdentifier res;
    int lastColon = enc.lastIndexOf(':');
    res.type = enc.mid(0,lastColon);
    std::string assetid;
    CryptoPP::StringSource(enc.mid(lastColon+1).toStdString(), true,
        new RFC4648Base32Decoder(
            new CryptoPP::StringSink(assetid)));
    res.id = QByteArray(assetid.data(), assetid.length());
    return res;
}

QString ExactIdentifier::base32id()
{
    std::string res;
    CryptoPP::StringSource((const byte*)id.data(), id.length(), true,
        new RFC4648Base32Encoder(
            new CryptoPP::StringSink(res)));
    return QString::fromStdString(res);
}

MagnetURI::MagnetURI() :
    xtIds(),
    size(0)
{
}

bool MagnetURI::parse(QString uri)
{
    if (!uri.startsWith(MAGNET_PREFIX))
        return false;
    uri = uri.mid(MAGNET_PREFIX.length());
    QStringList optionList = uri.split('&', QString::SkipEmptyParts);
    foreach (QString option, optionList) {
        QString key = option.section('=', 0, 0);
        QString value = option.section('=', 1);
        if (key == "xl")
            size = value.toInt();
        else if (key == "xt")
            xtIds.append(ExactIdentifier::fromUrlEnc(value));
    }
    return true;
}
