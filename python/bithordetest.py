import atexit, base64, os, shutil, socket, sys, types
from time import time

from bithorde import decodeMessage, encoder, MSG_REV_MAP, message

import eventlet
from eventlet.processes import Process
from google.protobuf.message import Message

class TestConnection:
    def __init__(self, tgt, name=None):
        if isinstance(tgt, eventlet.greenio.GreenSocket):
            self._socket = tgt
        elif isinstance(tgt, BithordeD):
            server_cfg = tgt.config['server']
            self._connect(server_cfg.get('unixSocket') or ('localhost', server_cfg.get('tcpPort')))
        else:
            _connect(tgt)
        self.buf = ""
        if name:
            self.auth(name)

    def _connect(self, tgt):
        if isinstance(tgt, tuple):
            family = socket.AF_INET
        else:
            family = socket.AF_UNIX
        self._socket = eventlet.connect(tgt, family)

    def send(self, msg):
        enc = encoder.MessageEncoder(MSG_REV_MAP[type(msg)], False, False)
        enc(self.push, msg)

    def close(self):
        self._socket.close()

    def __iter__(self):
        return self

    def next(self):
        while True:
            try:
                msg, consumed = decodeMessage(self.buf)
                self.buf = self.buf[consumed:]
                return msg
            except IndexError:
                self.buf += self.fetch()

    def fetch(self):
        new = self._socket.recv(128*1024)
        if not new:
            raise StopIteration
        return new

    def push(self, str):
        self._socket.send(str)

    @classmethod
    def _matches(cls, msg, criteria):
        if isinstance(criteria, type):
            return isinstance(msg, criteria)
        elif isinstance(criteria, message.message.Message):
            if not isinstance(msg, type(criteria)):
                return False
            for field, value in criteria.ListFields():
                if getattr(msg, field.name) != value:
                    return False
            return True
        else:
            assert False, "Criteria %s not supported" % criteria

    def expect(self, criteria):
        next = self.next()
        assert self._matches(next, criteria), "Next message %s did not match expected %s" % (next, criteria)
        return next

    def auth(self, name="bhtest"):
        self.send(message.HandShake(name=name, protoversion=2))
        self.expect(message.HandShake)

class BithordeD(Process):
    def __init__(self, label='bithorded', bithorded=os.environ.get('BITHORDED', 'bithorded'), config={}):
        if hasattr(config, 'setdefault'):
            suffix = (time(), os.getpid())
            server_cfg = config.setdefault('server', {})
            server_cfg.setdefault('tcpPort', 0)
            server_cfg.setdefault('inspectPort', 0)
            server_cfg.setdefault('unixSocket', "bhtest-sock-%d-%d" % suffix)
            cache_cfg = config.setdefault('cache', {})
            if not cache_cfg.get('dir'):
                d = 'bhtest-cache-%d-%d' % suffix
                os.mkdir(d)
                cache_cfg['dir'] = d

        self.config = config
        self.label = label
        self.started = False
        self.queue = eventlet.Queue()
        Process.__init__(self, 'stdbuf', ['-o0', '-e0', bithorded, '-c', '/dev/stdin'])
    def run(self):
        Process.run(self)
        atexit.register(self.kill)
        def gen_config(value, key=[]):
            if hasattr(value, 'iteritems'):
                return "\n".join(gen_config(value, key+[ikey]) for ikey, value in value.iteritems())
            elif key:
                return "%s=%s" % ('.'.join(key), value)
            else:
                return value
        self.write(gen_config(self.config))
        self.close_stdin()
        for line in self.child_stdout_stderr:
            if self.label:
                print "%s: %s" % (self.label, line.rstrip())
            if line.find('Server started') >= 0:
                self.started = True
                break
        assert self.started
        eventlet.spawn(self._run)
    def is_alive(self):
        return self.popen4.poll() == -1
    def _run(self):
        for line in self.child_stdout_stderr:
            if self.label:
                print "%s: %s" % (self.label, line.rstrip())
            self.queue.put(line)
    def wait_for(self, crit):
        while True:
            line = self.queue.get()
            if line.find(crit) >= 0:
                return True
        assert False, "%s: did not find expected '%s'" % (self.label, crit)

class TestFolder(object):
    def __init__(self, path="test-cache"):
        self.path = path
        if self.path:
            shutil.rmtree(path, ignore_errors=True)
    def __str__(self):
        return self.path

class Cache(TestFolder):
    pass

def TigerId(base32):
    padding = (((len(base32)+7)/8)*8 - len(base32))
    base32 = base32 + '='*padding # Pad up to even multiple of 8
    return message.Identifier(type=message.TREE_TIGER, id=base64.b32decode(base32))

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
