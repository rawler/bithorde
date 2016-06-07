#!/usr/bin/env python2

from bithordetest import message, BithordeD, TestConnection

if __name__ == '__main__':
    bithorded = BithordeD(config={
        'friend.deadservant.addr': ''
    })
    server = TestConnection(bithorded, name='deadservant')
    conn = TestConnection(bithorded, name='tester')

    dummy_ids = [message.Identifier(type=message.TREE_TIGER, id='NON-EXISTANT')]

    # Send request, and wait for it to arrive at server and time out
    conn.send(message.BindRead(handle=1, ids=dummy_ids, timeout=50))
    req = server.expect(message.BindRead)
    bithorded.wait_for("Failed upstream deadservant")
    conn.expect(message.AssetStatus(handle=1, status=message.NOTFOUND))

    # BithordeD should now have closed the connection. Hold the confirmation.
    req = server.expect(message.BindRead(handle=req.handle, ids=[]))

    # Re-bind, now with responding source
    conn.send(message.BindRead(handle=1, ids=dummy_ids, timeout=5000))
    req2 = server.expect(message.BindRead(ids=dummy_ids))
    assert req.handle != req2.handle # Since we did not confirm the close before, bithorde should not yet have re-used the handle.
    server.send(message.AssetStatus(handle=req2.handle, ids=req2.ids, status=message.SUCCESS))
    conn.expect(message.AssetStatus(handle=1, status=message.SUCCESS))

    # Now close both handles and confirm the closing
    server.send(message.AssetStatus(handle=req.handle, status=message.NOTFOUND))
    conn.send(message.BindRead(handle=1)) # We have to close the client-reference first
    req2 = server.expect(message.BindRead(ids=[]))
    server.send(message.AssetStatus(handle=req2.handle, status=message.NOTFOUND))
    conn.expect(message.AssetStatus(handle=1, status=message.NOTFOUND))

    # Re-bind a third time
    conn.send(message.BindRead(handle=1, ids=dummy_ids, timeout=5000))
    req3 = server.expect(message.BindRead(ids=dummy_ids))
    assert req3.handle in (req.handle, req2.handle) # Both handles should now be available
    server.send(message.AssetStatus(handle=req3.handle, ids=req3.ids, status=message.SUCCESS))
    conn.expect(message.AssetStatus(handle=1, status=message.SUCCESS))
