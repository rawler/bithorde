# -*- coding: utf-8 -*-
'''
Python library for querying BitHorde nodes. Currently only implements opening and closing
assets. More to come later.

Twisted-based implementation.
'''

import socket
import os, os.path

import bithorde_pb2 as message

from twisted.internet import reactor, protocol

from google.protobuf import descriptor
from google.protobuf.internal import encoder,decoder

# Protocol imports and definitions
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

class HandleAllocator(object):
    '''Stack-like allocator for keeping track of used and unused handles.'''
    def __init__(self):
        self._reusequeue = []
        self._counter = 0

    def allocate(self):
        if len(self._reusequeue):
            return self._reusequeue.pop()
        else:
            self._counter += 1
            return self._counter

    def deallocate(self, handle):
        self._reusequeue.append(handle)

class AssetMap(list):
    '''Simple overloaded auto-growing list to map assets to their handles.'''
    def __setitem__(self, k, v):
        l = len(self)
        if l <= k:
            self.extend((None,)*((k-l)+2))
        return list.__setitem__(self, k, v)

class Connection(protocol.Protocol):
    '''Twisted-driven connection to BitHorde'''
    def connectionMade(self):
        '''!Twisted-API! Once connected, send a handshake and wait for the other
        side.'''
        self.buf = ""

    def dataReceived(self, data):
        '''!Twisted-API! When data arrives, append to buffer and try to parse into
        BitHorde-messages'''
        self.buf += data

        dataleft = True
        while dataleft:
            buf = self.buf
            try:
                id, newpos = decoder._DecodeVarint32(buf,0)
                size, newpos = decoder._DecodeVarint32(buf,newpos)
                id = id >> 3
                msgend = newpos+size
                if msgend > len(buf):
                    dataleft = False
            except IndexError:
                dataleft = False

            if dataleft:
                self.buf = buf[msgend:]
                msg = MSGMAP[id].message_type._concrete_class()
                msg.ParseFromString(buf[newpos:msgend])

                self.msgHandler(msg)

    def writeMsg(self, msg):
        '''Serialize a BitHorde-message and write to the underlying Twisted-transport.'''
        enc = encoder.MessageEncoder(MSG_REV_MAP[type(msg)], False, False)
        enc(self.transport.write, msg)

    def close(self):
        self.transport.loseConnection()

class Client(Connection):
    '''Overrides a BitHorde-connection with Client-semantics. In particular provides
    client-handle-mappings and connection-state-logic.'''
    def connectionMade(self, userName = "python_bithorde"):
        self.remoteUser = None
        self.msgHandler = self._preAuthState
        self._assets = AssetMap()
        self._handles = HandleAllocator()
        Connection.connectionMade(self)

        handshake = message.HandShake()
        handshake.name = userName
        handshake.protoversion = 1
        self.writeMsg(handshake)

    def nodeConnected(self):
        '''Event triggered once a connection has been established, and authentication is done.'''
        pass

    def allocateHandle(self, asset):
        '''Allocates a handle for the provided implementation, and assign it a handle'''
        assert(asset.handle is None)
        asset.client = self
        asset.handle = handle = self._handles.allocate()
        self._assets[handle] = asset
        return asset

    def _bind(self, asset):
        '''Try to open asset'''
        assert(self.msgHandler == self._mainState)
        assert(asset is not None)
        msg = message.BindRead()
        msg.handle = asset.handle

        for t,v in asset.hashIds.iteritems():
            id = msg.ids.add()
            id.type = t
            id.id = v
        msg.timeout = 1000
        self.writeMsg(msg)

    def _closeAsset(self, handle):
        '''Unbind an asset from this Client and notify upstream.'''
        asset = self._assets[handle]
        self._assets[handle] = None
        if asset:
            asset.handle = None
        self._handles.deallocate(handle)
        msg = message.BindRead()
        msg.handle = handle
        self.writeMsg(msg)

    def _preAuthState(self, msg):
        '''Validates handshake and then changes state to _mainState'''
        if msg.DESCRIPTOR.name != "HandShake":
            print "Error: unexpected msg %s for preauth state." % msg.DESCRIPTOR.name
            self.close()
        self.remoteUser = msg.name
        self.protoversion = msg.protoversion
        self.msgHandler = self._mainState
        self.nodeConnected()

    def _mainState(self, msg):
        '''The main msg-reaction-routine, used after handshake.'''
        if isinstance(msg, message.AssetStatus):
            asset = self._assets[msg.handle]
            if asset:
                asset.onStatusUpdate(msg)

class Asset(object):
    '''Base-implementation of a BitHorde asset. For practical purposes, subclass and
    override onStatusUpdate.

    An asset have 4 states.
    1. "Created"
    2. "Allocated" through Client.allocateHandle
    3. "Bound" after call to bind. In this stage, the asset recieves statusUpdates.
    4. "Closed" after call to close
    '''
    def __init__(self):
        '''Creates a new Asset, unbound to any particular client instance.'''
        self.handle = None

    def bind(self, hashIds):
        '''Binds the asset to the provided hashIds'''
        self.hashIds = hashIds
        self.client._bind(self)

    def close(self):
        '''Closes the asset.'''
        assert(self.client and self.handle)
        self.client._closeAsset(self.handle)

    def onStatusUpdate(self, status):
        '''Should probably be overridden in subclass to react to status-changes.'''
        pass

class ClientFactory(protocol.ClientFactory):
    '''!Twisted-API! Twisted-factory for creating Client-instances for new connections.

    You will most likely want to subclass and override clientConnectionFailed and
    clientConnectionLost.
    '''
    def __init__(self, c):
        self.protocol = c

if __name__ == '__main__':
    from base64 import b32decode
    import sys

    assetId = None

    class MyAsset(Asset):
        def onStatusUpdate(self, status):
            print "Asset status: %s" % status
            Asset.onStatusUpdate(self, status)
            self.client.close()

    class MyClient(Client):
        def nodeConnected(self):
            print "Node (%s) connected, asking for asset." % (self.remoteUser)
            asset = MyAsset()
            self.allocateHandle(asset)
            asset.bind({message.TREE_TIGER: assetId})

    class MyFactory(ClientFactory):
        def clientConnectionFailed(self, connector, reason):
            print "Connection failed - goodbye!"
            reactor.stop()

        def clientConnectionLost(self, connector, reason):
            print "Connection lost - goodbye!"
            reactor.stop()

    if len(sys.argv) == 2:
        assetId = b32decode(sys.argv[1], True)
        reactor.connectUNIX("/tmp/bithorde", MyFactory(MyClient))
        reactor.run()
    else:
        print "Usage: %s <tiger tree hash: base32>" % sys.argv[0]

