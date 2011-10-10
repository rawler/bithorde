#ifndef MAIN_H
#define MAIN_H

#include <QtCore/QByteArray>
#include <QtCore/QFile>
#include <QtCore/QObject>

#include <client.h>
#include <cliprogressbar.h>

class BHUpload : public QObject {
    Q_OBJECT

    UploadAsset * upload;
    Client * client;
    QByteArray nextBlock;
    QFile src;
    quint64 offset;
    CLIProgressBar * progressBar;

public:
    explicit BHUpload(Client *parent, QString fileName);

public slots:
    void onAuthenticated(QString remoteName);

    void onUploadResponse(const bithorde::AssetStatus & msg);
    void tryWriteMore();

    void updateProgress();
};

#endif // MAIN_H
