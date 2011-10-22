#ifndef MAGNETURI_H
#define MAGNETURI_H

#include <QtCore/QObject>
#include <QtCore/QString>
#include <QtCore/QVector>

struct ExactIdentifier {
    QString type;
    QByteArray id;

    static ExactIdentifier fromUrlEnc(QString enc);

    QString base32id();
};

class MagnetURI
{
public:
    explicit MagnetURI();
    bool parse(QString uri);

    QVector<ExactIdentifier> xtIds;
    quint64 size;
};

#endif // MAGNETURI_H
