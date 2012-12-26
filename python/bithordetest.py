import sys,types

from bithorde import Connection, message as Message, connectUNIX, reactor
from twisted.internet.protocol import Factory, ProcessProtocol
from twisted.internet.endpoints import UNIXClientEndpoint
from twisted.internet import defer

class AsyncMessageQueue(object):
    def __init__(self):
        object.__init__(self)
        self.msgs = list()
        self.waiting = list()

    def __call__(self, msg):
        if self.waiting:
            self.waiting.pop(0).callback(msg)
        else:
            self.msgs.append(msg)

    def get(self):
        d = defer.Deferred()
        if (self.msgs):
            d.callback(self.msgs.pop(0))
        else:
            self.waiting.append(d)
        return d

    def expect(self, crit):
        def test_class(x):
          if not isinstance(x, crit):
              raise "Error, object was not of type %s" % crit
          return x
        d = self.get()
        if isinstance(crit, (type, types.ClassType)):
          d.addCallback(test_class)
        else:
          raise ArgumentError, "Unknown criteria-type"
        return d

class TestConnection(Connection):

    def connectionMade(self):
        Connection.connectionMade(self)
        self.msgHandler=AsyncMessageQueue()

    def auth(self, name="bhtest"):
        self.writeMsg(Message.HandShake(name=name, protoversion=2))
        d = self.msgHandler.expect(Message.HandShake)
        return d

class BithordeConnectionFactory(Factory):
    def buildProtocol(self, addr):
        return TestConnection()

    def connect(self, addr):
      point = UNIXClientEndpoint(reactor, addr)
      return point.connect(self)

    def connectAndAuth(self, addr):
      res = defer.Deferred()
      d = self.connect(addr) \
              .addCallbacks(lambda c: c.auth().addCallback(res.callback), res.errback)
      return res

class BithordeD(ProcessProtocol):
    @classmethod
    def launch(cls, label='bithorded', bithorded='bin/bithorded', config=''):
        self = cls()
        self.onStarted = defer.Deferred()
        self.config = config
        self.label = label
        reactor.spawnProcess(self, 'stdbuf', ['stdbuf', '-o0', '-e0', bithorded, '-c', '/dev/stdin'])
        return self.onStarted
    def connectionMade(self):
        self.exitTrigger = reactor.addSystemEventTrigger('before', 'shutdown', self.stop)
        self.transport.write(self.config)
        self.transport.closeStdin()
    def outReceived(self, data):
        self.onStarted.callback(self)
        print self.label, 'OUT:', data
    def errReceived(self, data):
        print >>sys.stderr, self.label, 'ERR:', data
    def stop(self):
        self.exitTrigger = None
        self.transport.signalProcess('KILL')
    def outConnectionLost(self):
        if self.exitTrigger:
            reactor.removeSystemEventTrigger(self.exitTrigger)

if __name__ == '__main__':
    from os import path
    TEST_SOCKET = path.abspath('bithorde-test')

    def authSuccess(x):
        print x
        reactor.stop()

    def authFail(err):
        print err
        reactor.stop()

    def bithordeStarted(process):
        BithordeConnectionFactory() \
            .connectAndAuth(TEST_SOCKET) \
            .addCallbacks(authSuccess, authFail)

    BithordeD.launch(config='''
        server.unixSocket=%s
        cache.dir=/tmp
    '''%TEST_SOCKET).addCallback(bithordeStarted)

    reactor.run()
