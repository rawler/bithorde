#!/usr/bin/env python

from bithordetest import message, BithordeD, TestConnection

import struct
from cStringIO import StringIO

from eventlet import greenthread

ASSET_SIZE=8*1024*1024

def generate(offset, size):
    assert((offset % 4) == 0)
    assert((size % 4) == 0)
    offset /= 4
    size /= 4
    res = StringIO()
    for i in xrange(offset, offset+size):
        res.write(struct.pack('!L', i))
    return res.getvalue()

import hashlib

def responder(conn):
    try:
        while True:
            req = conn.expect(message.Read.Request)
            res = generate(req.offset, req.size)
            conn.send(message.Read.Response(reqId=req.reqId, status=message.SUCCESS, offset=req.offset, content=res))
    except Exception as err:
        print err

if __name__ == '__main__':
    import os, random, shutil
    try:
        shutil.rmtree('cache')
    except OSError:
        pass
    bithorded = BithordeD(config={
        'friend.server.addr': '',
        'cache': {
            'dir': 'cache',
            'size': 8192,
        },
    })
    server = TestConnection(bithorded, name='server')
    client = TestConnection(bithorded, name='client')

    dummy_ids = [message.Identifier(type=message.TREE_TIGER, id='NON-EXISTANT')]

    # Send request, and wait for it to arrive at server and time out
    client.send(message.BindRead(handle=1, ids=dummy_ids, timeout=50))
    server_asset = server.expect(message.BindRead)
    server.send(message.AssetStatus(handle=server_asset.handle, ids=server_asset.ids, size=ASSET_SIZE, status=message.SUCCESS))
    client.expect(message.AssetStatus(handle=1, status=message.SUCCESS))

    assert len(os.listdir('cache/assets')) == 0 # Delayed cache-creation works.

    resp_thread = greenthread.spawn(responder, server)

    for i in xrange(64, 4096, 64):
        client.send(message.Read.Request(reqId=1, handle=1, offset=i*4, size=i, timeout=2000))
        resp = client.expect(message.Read.Response(reqId=1, status=message.SUCCESS))
        assert resp.content == generate(resp.offset, len(resp.content))

    rand = random.Random(0)

    for _ in xrange(64):
        size = (1 + rand.randrange(16*1024)) * 4
        offset = rand.randrange((ASSET_SIZE-size)/4)*4
        client.send(message.Read.Request(reqId=1, handle=1, offset=offset, size=size, timeout=30000))
        resp = client.expect(message.Read.Response(reqId=1, status=message.SUCCESS))
        assert resp.content == generate(resp.offset, len(resp.content))

    for offset in xrange(0, ASSET_SIZE, 8192):
        client.send(message.Read.Request(reqId=1, handle=1, offset=i, size=8192, timeout=30000))
        resp = client.expect(message.Read.Response(reqId=1, status=message.SUCCESS))
        assert resp.content == generate(resp.offset, len(resp.content))

    assert len(os.listdir('cache/assets')) == 1
