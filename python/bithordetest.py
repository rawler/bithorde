import types

from bithorde import Connection, message as Message, connectUNIX, reactor
from twisted.internet.protocol import Factory
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

if __name__ == '__main__':
    def authSuccess(x):
        print x
        reactor.stop()

    def authFail(err):
        print err
        reactor.stop()

    BithordeConnectionFactory() \
        .connectAndAuth('/tmp/bithorde') \
        .addCallbacks(authSuccess, authFail)
    reactor.run()
