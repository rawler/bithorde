module daemon.client;

private import tango.io.Stdout;
private import tango.net.SocketConduit;

import lib.client;
import lib.message;
import lib.protobuf;

class Client : lib.client.Client {
public:
    this (SocketConduit s)
    {
        super(s);
    }
protected:
    void processRequest(BitHordeMessage req) {
        switch (req.type) {
            case BitHordeMessage.Type.OpenRequest: processOpenRequest(req); break;
            default:
                Stdout.format("Unknown request type: {}", req.type);
        }
    }
private:
    void sendResponse(BitHordeMessage req, BitHordeMessage.Type type, ProtoBufMessage content)
    {
        scope auto resp = new BitHordeMessage;
        resp.type = type;
        resp.id = req.id;
        resp.content = content.encode();
        sendMessage(resp);
    }

    void processOpenRequest(BitHordeMessage req)
    {
        Stdout("Got open Request").newline;
        auto reqData = new BHOpenRequest;
        reqData.decode(req.content);
        auto respData = new BHOpenResponse;
        respData.handle = 0;
        respData.distance = 1;
        respData.size = 1400;
        sendResponse(req, BitHordeMessage.Type.OpenResponse, respData);
    }

}