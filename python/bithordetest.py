import socket, sys,types

from bithorde import decodeMessage, encoder, MSG_REV_MAP, message

import eventlet
from eventlet.processes import Process
from google.protobuf.message import Message

class TestConnection:
    def __init__(self, tgt, name=None):
        if isinstance(tgt, tuple):
            family = socket.AF_INET
        else:
            family = socket.AF_UNIX
        self._socket = eventlet.connect(tgt, family)
        self.buf = ""
        if name:
            self.auth(name)

    def send(self, msg):
        enc = encoder.MessageEncoder(MSG_REV_MAP[type(msg)], False, False)
        enc(self._socket.send, msg)

    def __iter__(self):
        return self

    def next(self):
        while True:
            try:
                msg, consumed = decodeMessage(self.buf)
                self.buf = self.buf[consumed:]
                return msg
            except IndexError:
                new = self._socket.recv(4096)
                if not new:
                    raise StopIteration
                self.buf += new

    @classmethod
    def _matches(cls, msg, criteria):
        if isinstance(criteria, type):
            return isinstance(msg, criteria)
        else:
            assert False, "Criteria %s not supported" % criteria

    def expect(self, criteria):
        assert self._matches(self.next(), criteria)

    def auth(self, name="bhtest"):
        self.send(message.HandShake(name=name, protoversion=2))
        self.expect(message.HandShake)


class BithordeD(Process):
    def __init__(self, label='bithorded', bithorded='bithorded', config=''):
        self.config = config
        self.label = label
        Process.__init__(self, 'stdbuf', ['-o0', '-e0', bithorded, '-c', '/dev/stdin'])
    def run(self):
        Process.run(self)
        self.write(self.config)
        self.close_stdin()
        for line in self.child_stdout_stderr:
            if self.label:
                print "%s: %s" % (self.label, line)
            if line.find('Server started') >= 0:
                break
        eventlet.spawn(self._run)
    def _run(self):
        for line in self.child_stdout_stderr:
            pass

if __name__ == '__main__':
    from os import path
    TEST_SOCKET = path.abspath('test-bithorde-sock')

    bithorde = BithordeD(bithorded='bin/bithorded', config='''
        server.tcpPort=0
        server.unixSocket=%s
        cache.dir=/tmp
    '''%TEST_SOCKET)

    conn = TestConnection(TEST_SOCKET, name='test-python')
    conn.send(message.BindRead(handle=1, ids=[message.Identifier(type=message.TREE_TIGER, id='NON-EXISTANT')]))
    for msg in conn:
        print msg
