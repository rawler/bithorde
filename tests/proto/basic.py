#!/usr/bin/env python

from bithordetest import message, BithordeD, Cache, TestConnection, TigerId

if __name__ == '__main__':
    ASSET = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    ASSET_TTH = "4KUEWKWPZXQ2I3I6CC2DQCMWTKBQEEHNGGWHXQQ"

    bithorded = BithordeD(config={
        'cache': {'dir': Cache() },
        'client.tester.addr': '',
    })
    conn = TestConnection(bithorded, name='tester')

    # Open an invalid handle
    conn.send(message.BindRead(handle=1, ids=[TigerId("IDONOTEXISTO")], timeout=500))
    conn.expect(message.AssetStatus(handle=1, status=message.NOTFOUND))

    # Create small asset
    conn.send(message.BindWrite(handle=1, size=len(ASSET)))
    conn.expect(message.AssetStatus(handle=1, status=message.SUCCESS))

    conn.send(message.DataSegment(handle=1, offset=0, content=ASSET))
    conn.expect(message.AssetStatus(handle=1, status=message.SUCCESS, ids=[TigerId(ASSET_TTH)]))

    conn.send(message.BindRead(handle=1, ids=[TigerId(ASSET_TTH)], timeout=500))
    conn.expect(message.AssetStatus(handle=1, status=message.SUCCESS, size=len(ASSET), ids=[TigerId(ASSET_TTH)]))

    conn.send(message.Read.Request(reqId=1, handle=1, offset=0, size=len(ASSET), timeout=500))
    conn.expect(message.Read.Response(reqId=1, status=message.SUCCESS, offset=0, content=ASSET))

    conn.send(message.BindRead(handle=1))
    conn.expect(message.AssetStatus(handle=1, status=message.NOTFOUND))
