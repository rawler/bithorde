#!/usr/bin/env python

from bithordetest import message, BithordeD, TestConnection

if __name__ == '__main__':
    bithorded = BithordeD(config={
        'friend.evilservant.addr': ''
    })
    conn = TestConnection(bithorded, name='tester')
    server = TestConnection(bithorded, name='evilservant')

    # Open a valid handle
    conn.send(message.BindRead(handle=1, ids=[message.Identifier(type=message.TREE_TIGER, id='NON-EXISTANT')], timeout=500))
    assetReq = server.expect(message.BindRead)
    server.send(message.AssetStatus(handle=assetReq.handle, ids=assetReq.ids, status=message.SUCCESS, size=1024))
    conn.expect(message.AssetStatus(handle=1, ids=assetReq.ids, status=message.SUCCESS))

    # Send a pending read-request.
    conn.send(message.Read.Request(reqId=1, handle=1, offset=0, size=1024, timeout=500))
    server.expect(message.Read.Request(handle=assetReq.handle, offset=0, size=1024))

    # Close upstream server
    server.close()
    bithorded.wait_for("Disconnected: evilservant")
    conn.expect(message.Read.Response(reqId=1, status=message.NOTFOUND, offset=0, content=''))
    conn.expect(message.AssetStatus(handle=1, status=message.NOTFOUND))

    # Reconnect upstream server
    server = TestConnection(bithorded, name='evilservant')

    # Expect a BindRead to arrive for the stale asset
    server.expect(message.BindRead(handle=assetReq.handle, ids=assetReq.ids))
    server.send(message.AssetStatus(handle=assetReq.handle, ids=assetReq.ids, size=1024, status=message.SUCCESS))
    conn.expect(message.AssetStatus(handle=1, ids=assetReq.ids, status=message.SUCCESS))

    # Verify working resend of read
    conn.send(message.Read.Request(reqId=1, handle=1, offset=0, size=1024, timeout=500))
    readReq = server.expect(message.Read.Request(handle=assetReq.handle, offset=0, size=1024))
    server.send(message.Read.Response(reqId=readReq.reqId, status=message.SUCCESS, offset=0, content='A'*1024))
    conn.expect(message.Read.Response(reqId=1, status=message.SUCCESS, offset=0, content='A'*1024))
