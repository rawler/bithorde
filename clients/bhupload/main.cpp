
#include <QtCore/QCoreApplication>
#include <QtCore/QStringList>
#include <QtCore/QTextStream>
#include <QtNetwork/QHostAddress>
#include <QtNetwork/QLocalSocket>
#include <QtNetwork/QTcpSocket>

#include <libqhorde.h>

#include <crypto++/filters.h>
#include <crypto++/base32.h>

#include "main.h"

#define BLOCKSIZE (64*1024)

static QTextStream qerr(stderr);
static QTextStream qout(stdout);

int main(int argc, char *argv[])
{
    QCoreApplication a(argc, argv);

    QLocalSocket sock;
    sock.connectToServer("/tmp/bithorde");
    LocalConnection conn(sock);

    BHUpload u(a.arguments()[1]);
    if (u.isOpen()) {
        u.setClient(new Client(conn, "testclient"));
        return a.exec();
    } else {
        return -1;
    }
}

BHUpload::BHUpload(QString fileName) :
    src(fileName),
    offset(0),
    progressBar(NULL)
{
    if (src.open(QIODevice::ReadOnly)) {
        nextBlock = src.read(BLOCKSIZE);
    } else {
        qerr << "open(" << src.fileName() << ") error: " << src.errorString() << "\n";
    }
}

bool BHUpload::isOpen()
{
    return src.isOpen();
}

void BHUpload::setClient(Client *client)
{
    this->client = client;

    connect(client, SIGNAL(authenticated(QString)), SLOT(onAuthenticated(QString)));
}


void BHUpload::onAuthenticated(QString remoteName)
{
    qout << "Uploading " << src.fileName() << " (" << src.size()/1024 << "KB) to " << remoteName << "\n";

    Client * client = (Client*)sender();
    upload = new UploadAsset(client, this);
    upload->setSize(src.size());
    connect(upload, SIGNAL(statusUpdate(const bithorde::AssetStatus&)), SLOT(onUploadResponse(const bithorde::AssetStatus&)));
    client->bindWrite(*upload);
}

void BHUpload::onUploadResponse(const bithorde::AssetStatus &msg)
{
    if (msg.status() == bithorde::SUCCESS) {
        if (msg.ids_size() > 0) {
            const::std::string id = msg.ids(0).id();
            std::string base32id;
            CryptoPP::StringSource((const byte*)id.data(), id.length(), true,
                getBase32Encoder(base32id));

            qout << "magnet:?xl=" << msg.size() << "&xt=urn:tree:tiger:" << base32id.c_str() << "\n";
            QCoreApplication::exit();
        } else {
            progressBar = new CLIProgressBar(&qerr, this);
            QObject::connect(progressBar, SIGNAL(update()), SLOT(updateProgress()));
            QObject::connect(client, SIGNAL(sent()), SLOT(tryWriteMore()));
            tryWriteMore();
        }
    } else {
        qout << "Failure, got " << bithorde::Status_Name(msg.status()).c_str() << "\n";
        QCoreApplication::exit(-1);
    }
}

void BHUpload::tryWriteMore() {
    while ((!nextBlock.isEmpty()) && upload->tryWrite(offset, nextBlock)) {
        offset += nextBlock.length();
        nextBlock = src.read(BLOCKSIZE);
    }
    if (nextBlock.isEmpty()) {
        if (progressBar)
            progressBar->finish();
        disconnect(client, SIGNAL(sent()), this, SLOT(tryWriteMore()));
    }
}

void BHUpload::updateProgress()
{
    progressBar->setProgress((float)offset / src.size());
}

