#!/usr/bin/env python

from bithordetest import message, BithordeD, TestConnection
from random import randint

ASSET_IDS = [message.Identifier(type=message.TREE_TIGER, id='GIS3CRGMSBT7CKRBLQFXFAL3K4YIO5P5E3AMC2A')]
INITIAL_REQUEST = randint(0,(2**64)-1)

if __name__ == '__main__':
    bithorded = BithordeD(config={
        'friend.upstream1.addr': '',
        'friend.upstream2.addr': '',
    })
    upstream1 = TestConnection(bithorded, name='upstream1')
    upstream2 = TestConnection(bithorded, name='upstream2')
    downstream1 = TestConnection(bithorded, name='downstream1')
    downstream2 = TestConnection(bithorded, name='downstream2')

    # Request an asset-session
    downstream1.send(message.BindRead(handle=1, ids=ASSET_IDS, timeout=500, requesters=[INITIAL_REQUEST]))
    req1 = upstream1.expect(message.BindRead)
    assert len(req1.requesters) > 1
    assert INITIAL_REQUEST in req1.requesters
    assert INITIAL_REQUEST == req1.requesters[-1] # Try to keep backwards compatibility
    server_id = next(x for x in req1.requesters if x != INITIAL_REQUEST)

    # Let upstream1 join as server
    upstream1.send(message.AssetStatus(handle=req1.handle, status=message.SUCCESS, ids=ASSET_IDS, servers=[99998888], size=15))
    resp = downstream1.expect(message.AssetStatus)
    assert len(resp.servers) > 1
    assert 99998888 in resp.servers
    assert server_id in resp.servers

    # Let upstream2 join as server
    req2 = upstream2.expect(message.BindRead)
    upstream2.send(message.AssetStatus(handle=req2.handle, status=message.SUCCESS, ids=ASSET_IDS, servers=[12345], size=15))
    resp = downstream1.expect(message.AssetStatus)
    assert 99998888 in resp.servers
    assert server_id in resp.servers
    assert 12345 in resp.servers

    # Let upstream1 leave
    upstream1.send(message.AssetStatus(handle=req2.handle, status=message.NOTFOUND))
    resp = downstream1.expect(message.AssetStatus)
    assert 99998888 not in resp.servers
    assert server_id in resp.servers
    assert 12345 in resp.servers

    # Add another downstream
    downstream2.send(message.BindRead(handle=1, ids=ASSET_IDS, timeout=500, requesters=[9873474]))
    req2 = upstream2.expect(message.BindRead)
    assert len(req2.requesters) > 2
    assert INITIAL_REQUEST in req2.requesters
    assert 9873474 in req2.requesters

    resp2 = downstream2.expect(message.AssetStatus(status=message.SUCCESS))

    # TODO: Should really not expect status-change on unaffected downstream.
    resp1 = downstream1.expect(message.AssetStatus(status=message.SUCCESS))

    # Simulate loop on client1
    downstream1.send(message.BindRead(handle=1, ids=ASSET_IDS, timeout=500, requesters=[9873474, 12345]))

    # TODO: Should really not expect status-change on unaffected downstream.
    resp1 = downstream1.expect(message.AssetStatus(status=message.SUCCESS))
    resp1 = downstream1.expect(message.AssetStatus(status=message.WOULD_LOOP))

    downstream1.send(message.BindRead(handle=1, ids=ASSET_IDS, timeout=500, requesters=[9873474]))
    resp1 = downstream1.expect(message.AssetStatus(status=message.SUCCESS))
