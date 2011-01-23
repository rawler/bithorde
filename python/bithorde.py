# -*- coding: utf-8 -*-

import socket
import os, os.path

import bithorde_pb2 as message

from twisted.internet import reactor, protocol

from google.protobuf import descriptor
from google.protobuf.internal import encoder,decoder

MSGMAP = message.Stream.DESCRIPTOR.fields_by_number
MSG_REV_MAP = {
    message.HandShake:     1,
    message.BindRead:      2,
    message.AssetStatus:   3,
    message.Read.Request:  5,
    message.Read.Response: 6,
    message.BindWrite:     7,
    message.DataSegment:   8,
}

class Asset(object):
    pass

class Connection(protocol.Protocol):
    """Once connected, send a message, then print the result."""
    def connectionMade(self, userName = "python_bithorde"):
        self.buf = ""

        handshake = message.HandShake()
        handshake.name = userName
        handshake.protoversion = 1
        self.writeMsg(handshake)

    def dataReceived(self, data):
        print "Server said:", data
        self.buf += data
        buf = self.buf

        id, newpos = decoder._DecodeVarint32(buf,0)
        size, newpos = decoder._DecodeVarint32(buf,newpos)
        id = id >> 3
        msgend = newpos+size
        assert(msgend <= len(buf))
        self.buf = buf[msgend:]

        msg = MSGMAP[id].message_type._concrete_class()
        msg.ParseFromString(buf[newpos:msgend])

        self.msgHandler(msg)

    def writeMsg(self, msg):
        enc = encoder.MessageEncoder(MSG_REV_MAP[type(msg)], False, False)
        enc(self.transport.write, msg)

    def connectionLost(self, reason):
        print "connection lost"

    def close(self):
        self.transport.loseConnection()

class Client(Connection):
    def connectionMade(self):
        self.remoteUser = None
        self.msgHandler = self._preAuthState
        Connection.connectionMade(self)

    def _preAuthState(self, msg):
        if msg.DESCRIPTOR.name != "HandShake":
            print "Error: unexpected msg %s for preauth state." % msg.DESCRIPTOR.name
            self.close()
        self.remoteUser = msg.name
        self.protoversion = msg.protoversion
        self.nodeConnected()
        self._state = self._mainState

    def _mainState(self, msg):
        print msg

class ClientFactory(protocol.ClientFactory):
    def __init__(self, c):
        self.protocol = c

    def clientConnectionFailed(self, connector, reason):
        print "Connection failed - goodbye!"
        reactor.stop()

    def clientConnectionLost(self, connector, reason):
        print "Connection lost - goodbye!"
        reactor.stop()

if __name__ == '__main__':
    class MyClient(Client):
        def nodeConnected(self):
            print "Node (%s) connected, shutting down." % (self.remoteUser)
            self.close()

    reactor.connectUNIX("/tmp/bithorde", ClientFactory(MyClient))
    reactor.run()

