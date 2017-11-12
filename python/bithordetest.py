
import atexit
import base64
import os
import socket
from time import time
from threading import Condition, Thread

from bithorde import decodeMessage, encodeMessage, message

from subprocess import Popen, PIPE, STDOUT
from google.protobuf.message import Message


class TestConnection:
    def __init__(self, tgt, name=None):
        if isinstance(tgt, socket.socket):
            self._socket = tgt
        elif isinstance(tgt, BithordeD):
            server_cfg = tgt.config['server']
            self._connect(server_cfg.get('unixSocket') or (
                'localhost', server_cfg.get('tcpPort')))
        else:
            self._connect(tgt)
        self.buf = ""
        if name:
            self.auth(name)

    def _connect(self, tgt):
        if isinstance(tgt, tuple):
            family = socket.AF_INET
        else:
            family = socket.AF_UNIX
        self._socket = socket.socket(family, socket.SOCK_STREAM)
        self._socket.connect(tgt)

    def send(self, msg):
        return encodeMessage(msg, self.push)

    def push(self, str):
        self._socket.sendall(str)

    def close(self):
        self._socket.shutdown(socket.SHUT_RDWR)
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
        new = self._socket.recv(128 * 1024)
        if not new:
            raise StopIteration
        return new

    @staticmethod
    def _crit_str(crit):
        if isinstance(crit, type):
            return str(crit)
        elif isinstance(crit, Message):
            return "%s(%s)" % (type(crit), crit)

    @classmethod
    def _matches(cls, msg, criteria):
        if hasattr(criteria, '__iter__'):
            for crit in criteria:
                if cls._matches(msg, crit):
                    return crit
            return None

        if isinstance(criteria, type):
            return isinstance(msg, criteria)
        elif isinstance(criteria, Message):
            if not isinstance(msg, type(criteria)):
                return False
            for field, value in criteria.ListFields():
                if getattr(msg, field.name) != value:
                    return False
            return criteria
        else:
            assert False, "Criteria %s not supported" % criteria

    def _check_next(self, criteria):
        next = self.next()
        crit = self._matches(next, criteria)
        assert crit, "Next message %s did not match expected %s" % (
            next, criteria)
        return next, crit

    def expect(self, criteria):
        if hasattr(criteria, '__iter__'):
            criteria = list(criteria)
            res = list()
            while criteria:
                next, crit = self._check_next(criteria)
                print "  -> Matched ", self._crit_str(crit)
                res.append(next)
                criteria.remove(crit)
            return res
        else:
            next, crit = self._check_next(criteria)
            return next

    def auth(self, name="bhtest"):
        self.send(message.HandShake(name=name, protoversion=2))
        self.expect(message.HandShake)


class LineBuffer(object):
    def __init__(self, label, f=None):
        self.buf = list()
        self.cv = Condition()
        self.label = label
        if f:
            t = Thread(target=self.feed, args=(f,))
            t.daemon = True
            t.start()

    def feed(self, f):
        line = f.readline()
        while line:
            if self.label:
                print "%s: %s" % (self.label, line.rstrip())
            with self.cv:
                self.buf.append(line)
                self.cv.notifyAll()
            line = f.readline()

        with self.cv:
            cv, self.cv = self.cv, None
            cv.notifyAll()

    def readlines(self):
        i = 0
        while True:
            line = None

            cv = self.cv
            if cv is None:
                return
            with cv:
                while i >= len(self.buf):
                    cv.wait()
                    if not self.cv:
                        return
                line = self.buf[i]
                i += 1

            yield line
    __iter__ = readlines


class BithordeD(Popen):
    def __init__(self, label='bithorded', bithorded=os.environ.get('BITHORDED', 'bithorded'), config={}):
        cmd = ['stdbuf', '-o0', '-e0', bithorded, '-c', '/dev/stdin', '--log.level=TRACE']
        Popen.__init__(self, cmd, stderr=STDOUT, stdout=PIPE, stdin=PIPE)
        self._cleanup = list()
        if hasattr(config, 'setdefault'):
            suffix = (time(), os.getpid())
            server_cfg = config.setdefault('server', {})
            server_cfg.setdefault('tcpPort', 0)
            server_cfg.setdefault('inspectPort', 0)
            server_cfg.setdefault('unixSocket', "bhtest-sock-%d-%d" % suffix)
            self._cleanup.append(lambda: os.unlink(server_cfg['unixSocket']))
            cache_cfg = config.setdefault('cache', {})
            if 'dir' not in cache_cfg:
                from shutil import rmtree
                d = 'bhtest-cache-%d-%d' % suffix
                self._cleanup.append(lambda: rmtree(d, ignore_errors=True))
                os.mkdir(d)
                cache_cfg['dir'] = d

        self.buffer = LineBuffer(label, self.stdout)
        self.config = config
        self.label = label
        self.started = False

        self._run()

    def cleanup(self):
        self.kill()
        for op in self._cleanup:
            op()

    def _run(self):
        atexit.register(self.cleanup)

        def gen_config(value, key=[]):
            if hasattr(value, 'iteritems'):
                return "\n".join(gen_config(value, key + [ikey]) for ikey, value in value.iteritems())
            elif key:
                return "%s=%s" % ('.'.join(key), value)
            else:
                return value
        self.stdin.write(gen_config(self.config))
        self.stdin.close()
        for line in self.buffer:
            if line.find('Server started') >= 0:
                self.started = True
                break
        assert self.started

    def is_alive(self):
        return self.poll() is None

    def wait_for(self, crit):
        for line in self.buffer:
            if line.find(crit) >= 0:
                return True
        assert False, "%s: did not find expected '%s'" % (self.label, crit)


class TestFolder(object):
    def __init__(self, path="test-cache"):
        from shutil import rmtree
        self.path = path
        if self.path:
            rmtree(path, ignore_errors=True)

    def __str__(self):
        return self.path


class Cache(TestFolder):
    pass


def TigerId(base32):
    padding = (((len(base32) + 7) / 8) * 8 - len(base32))
    base32 = base32 + '=' * padding  # Pad up to even multiple of 8
    return message.Identifier(type=message.TREE_TIGER, id=base64.b32decode(base32))


if __name__ == '__main__':
    from os import path
    TEST_SOCKET = path.abspath('test-bithorde-sock')

    bithorde = BithordeD(bithorded='bin/bithorded', config='''
        server.tcpPort=0
        server.unixSocket=%s
        cache.dir=/tmp
    ''' % TEST_SOCKET)

    conn = TestConnection(TEST_SOCKET, name='test-python')
    conn.send(message.BindRead(
        handle=1, ids=[message.Identifier(type=message.TREE_TIGER, id='NON-EXISTANT')]))
    for msg in conn:
        print msg
