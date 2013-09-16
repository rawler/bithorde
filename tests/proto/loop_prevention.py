#!/usr/bin/env python

from bithordetest import message, BithordeD, TestConnection

ASSET_IDS = [message.Identifier(type=message.TREE_TIGER, id='GIS3CRGMSBT7CKRBLQFXFAL3K4YIO5P5E3AMC2A')]

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
    downstream1.send(message.BindRead(handle=1, ids=ASSET_IDS, timeout=500, requesters=[162532344]))
    req1 = upstream1.expect(message.BindRead)
    assert len(req1.requesters) > 1
    assert 162532344 in req1.requesters
    server_id = [x for x in req1.requesters if x != 162532344][0]

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
    assert 162532344 in req2.requesters
    assert 9873474 in req2.requesters

    resp2 = downstream2.expect(message.AssetStatus(status=message.SUCCESS))

    # TODO: Should really not expect status-change on unaffected downstream.
    resp1 = downstream1.expect(message.AssetStatus(status=message.SUCCESS))

    # Simulate loop on client1
    downstream1.send(message.BindRead(handle=1, ids=ASSET_IDS, timeout=500, requesters=[9873474, 12345]))

    # TODO: Should really not expect status-change on unaffected downstream.
    resp1 = downstream1.expect(message.AssetStatus(status=message.SUCCESS))
    resp1 = downstream1.expect(message.AssetStatus(status=message.WOULD_LOOP))
