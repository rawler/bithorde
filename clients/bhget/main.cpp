#include <QtCore/QByteArray>
#include <QtCore/QCoreApplication>
#include <QtCore/QPair>
#include <QtCore/QStringList>
#include <QtCore/QTextStream>
#include <QtNetwork/QHostAddress>
#include <QtNetwork/QLocalSocket>
#include <QtNetwork/QTcpSocket>

#include <libqhorde.h>

#include "main.h"

static QTextStream qerr(stderr);
static QTextStream qout(stdout);

#define BLOCK_SIZE (64*1024)

struct OutQueue {
    typedef QPair<quint64, QByteArray> Chunk;
    quint64 position;
    QList<Chunk> _stored;

    OutQueue() :
        position(0)
    {}

    void _queue(quint64 offset, QByteArray & data) {
        int pos = 0;
        while ((pos < _stored.length()) && (_stored[pos].first < offset))
            pos += 1;
        _stored.insert(pos, Chunk(offset, data));
    }

    void _dequeue() {
        while (_stored.length()) {
            Chunk first = _stored.first();
            if (first.first > position) {
                break;
            } else {
                Q_ASSERT(first.first == position);
                _flush(first.second);
            }
        }
    }

    void _flush(QByteArray & data) {
        if (write(1, data.data(), data.length()) == data.length())
            position += data.length();
        else
            (qerr << "Error: failed to write block\n").flush();
    }

    void send(quint64 offset, QByteArray & data) {
        if (offset <= position) {
            Q_ASSERT(offset == position);

            _flush(data);
            _dequeue();
        } else {
            _queue(offset, data);
        }
    }
};

int main(int argc, char *argv[])
{
    QCoreApplication a(argc, argv);

    BHGet get("bhget");

    foreach (QString arg, a.arguments().mid(1)) {
        if (!get.queueAsset(arg)) {
            return -1;
        }
    }

    QLocalSocket sock;
    get.attach(sock);
    sock.connectToServer("/tmp/bithorde");

    return a.exec();
}

BHGet::BHGet(QString myName) :
    _myName(myName),
    _asset(NULL),
    _currentOffset(0)
{
}

bool BHGet::queueAsset(QString _uri)
{
    QUrl uri(_uri);
    if (uri.scheme() != "magnet") {
        qerr << "Only magnet-links supported, not '" << _uri << "'\n";
        return false;
    }
    bool found_id = false;
    typedef QPair<QString, QString> query_item;
    foreach (query_item item, uri.queryItems()) {
        if ((item.first == "xt") && item.second.startsWith("urn:tree:tiger:")) {
            found_id = true;
            break;
        }
    }

    if (found_id) {
        _assets.append(uri);
        return true;
    } else {
        qerr << "No hash-Identifier in '" << _uri << "'\n";
        return false;
    }
}

void BHGet::attach(QLocalSocket &sock)
{
    _connection = new LocalConnection(sock);
    _client = new Client(*_connection, _myName, this);
    connect(_client, SIGNAL(authenticated(QString)), SLOT(onAuthenticated(QString)));
}


void BHGet::nextAsset()
{
    if (_asset) {
        _asset->close();
        delete _asset;
        _asset = NULL;
    }

    QString hashId;
    while (hashId.isEmpty() && !_assets.isEmpty()) {
        QUrl nextUri = _assets.takeFirst();
        typedef QPair<QString, QString> query_item;
        foreach (query_item item, nextUri.queryItems()) {
            if ((item.first == "xt") && item.second.startsWith("urn:tree:tiger:")) {
                hashId = item.second.mid(14);
                break;
            }
        }
    }
    if (hashId.isEmpty())
        QCoreApplication::quit();

    std::string assetid;
    CryptoPP::StringSource(hashId.toStdString(), true,
        new RFC4648Base32Decoder(
            new CryptoPP::StringSink(assetid)));
    ReadAsset::IdList ids;
    ids.append(ReadAsset::Identifier(bithorde::TREE_TIGER, QByteArray(assetid.data(), assetid.length())));
    _asset = new ReadAsset(_client, ids);
    connect(_asset, SIGNAL(statusUpdate(bithorde::AssetStatus)), SLOT(onStatusUpdate(bithorde::AssetStatus)));
    connect(_asset, SIGNAL(dataArrived(quint64,QByteArray,int)), SLOT(onDataChunk(quint64,QByteArray,int)));
    _client->bindRead(*_asset);

    _outQueue = new OutQueue();
}

void BHGet::onAuthenticated(QString)
{
    nextAsset();
}

void BHGet::onStatusUpdate(bithorde::AssetStatus status)
{
    if (sender() != _asset)
        return;
    switch (status.status()) {
    case bithorde::SUCCESS:
        qerr << "Downloading ..." << "\n";
        requestMore();
        break;
    default:
        qerr << "Failed ..." << "\n";
        nextAsset();
        break;
    }
    qerr.flush();
}

void BHGet::requestMore()
{
    while (_currentOffset < (_outQueue->position + (BLOCK_SIZE*10)) &&
           _currentOffset < _asset->size()) {
        _asset->aSyncRead(_currentOffset, BLOCK_SIZE);
        _currentOffset += BLOCK_SIZE;
    }
}

void BHGet::onDataChunk(quint64 offset, QByteArray data, int tag)
{
    _outQueue->send(offset, data);
    if ((data.length() < BLOCK_SIZE) && ((offset+data.length()) < _asset->size())) {
        (qerr << "Error: got unexpectedly small data-block.\n").flush();
    }
    if (_outQueue->position < _asset->size()) {
        requestMore();
    } else {
        nextAsset();
    }
}
