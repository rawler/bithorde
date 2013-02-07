#!/usr/bin/env python

from os import path

from bithordetest import message, BithordeD, TestConnection

if __name__ == '__main__':
    TEST_SOCKET = path.abspath('test-bithorde-sock')
    bithorded = BithordeD(config='''
        server.tcpPort=0
        server.unixSocket=%s
        cache.dir=/tmp
        friend.deadservant.addr=
    '''%TEST_SOCKET)
    server = TestConnection(TEST_SOCKET, name='deadservant')
    conn = TestConnection(TEST_SOCKET, name='tester')
    conn.send(message.BindRead(handle=1, ids=[message.Identifier(type=message.TREE_TIGER, id='NON-EXISTANT')], timeout=50))
    bithorded.wait_for("Failed upstream deadservant")
    conn.expect(message.AssetStatus(handle=1, status=message.NOTFOUND))
