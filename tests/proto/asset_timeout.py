#!/usr/bin/env python

from bithordetest import message, BithordeD, TestConnection

if __name__ == '__main__':
    bithorded = BithordeD(config={
        'friend.deadservant.addr': ''
    })
    server = TestConnection(bithorded, name='deadservant')
    conn = TestConnection(bithorded, name='tester')

    conn.send(message.BindRead(handle=1, ids=[message.Identifier(type=message.TREE_TIGER, id='NON-EXISTANT')], timeout=50))
    bithorded.wait_for("Failed upstream deadservant")
    conn.expect(message.AssetStatus(handle=1, status=message.NOTFOUND))
