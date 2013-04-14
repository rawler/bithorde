# -*- coding: utf-8 -*-
'''
Python library for querying BitHorde nodes. Currently only implements opening and closing
assets. More to come later.

Twisted-based implementation.
'''

import socket
import os, os.path
from base64 import b32decode as _b32decode
from types import MethodType

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
DEFAULT_TIMEOUT=4000

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

def decodeMessage(buf):
    '''Decodes a single message from buffer
    @return (msg, bytesConsumed)
    @raises IndexError if buffer did not contain complete message
    '''
    id, newpos = decoder._DecodeVarint32(buf,0)
    size, newpos = decoder._DecodeVarint32(buf,newpos)
    id = id >> 3
    msgend = newpos+size
    if msgend > len(buf):
        raise IndexError, 'Incomplete message'
    msg = MSGMAP[id].message_type._concrete_class()
    msg.ParseFromString(buf[newpos:msgend])
    return msg, msgend

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

        while True:
            try:
                msg, consumed = decodeMessage(self.buf)
            except IndexError:
                break
            self.buf = self.buf[consumed:]
            self.msgHandler(msg)

    def writeMsg(self, msg):
        '''Serialize a BitHorde-message and write to the underlying Twisted-transport.'''
        enc = encoder.MessageEncoder(MSG_REV_MAP[type(msg)], False, False)
        enc(self.transport.write, msg)

class Client(Connection):
    '''Overrides a BitHorde-connection with Client-semantics. In particular provides
    client-handle-mappings and connection-state-logic.'''
    def connectionMade(self, userName = "python_bithorde"):
        self.closed = False

        self.remoteUser = None
        self.msgHandler = self._preAuthState
        self._assets = AssetMap()
        self._handles = HandleAllocator()
        Connection.connectionMade(self)

        handshake = message.HandShake()
        handshake.name = userName
        handshake.protoversion = 2
        self.writeMsg(handshake)

    def onConnected(self):
        '''Event triggered once a connection has been established, and authentication is done.'''
        pass

    def onDisconnected(self, reason):
        '''Event triggered if connection is terminated'''
        pass

    def onFailed(self, reason):
        '''Event triggered if connection failed to be established.'''
        pass

    def connectionLost(self, reason):
        return self.onDisconnected(reason)

    def close(self):
        if not self.closed:
            self.closed = True
            self.transport.loseConnection()

    def allocateHandle(self, asset):
        '''Assigns a newly allocated handle for the provided asset'''
        assert(asset.handle is None)
        asset.client = self
        asset.handle = handle = self._handles.allocate()
        self._assets[handle] = asset
        return asset

    def _bind(self, asset, timeout):
        '''Try to open asset'''
        assert(self.msgHandler == self._mainState)
        assert(asset is not None)
        msg = message.BindRead()
        msg.handle = asset.handle

        for t,v in asset.hashIds.iteritems():
            id = msg.ids.add()
            id.type = t
            id.id = v
        msg.timeout = timeout
        self.writeMsg(msg)

    def _closeAsset(self, handle):
        '''Unbind an asset from this Client and notify upstream.'''
        def _cleanupCallback(status):
            assert status and status.status == message.NOTFOUND
            self._assets[handle] = None
            self._handles.deallocate(handle)
        asset = self._assets[handle]
        if asset:
            asset.handle = None
            asset.onStatusUpdate = _cleanupCallback
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
        self.onConnected()

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

    def bind(self, hashIds, timeout=DEFAULT_TIMEOUT):
        '''Binds the asset to the provided hashIds'''
        self.hashIds = hashIds
        self.client._bind(self, timeout)

    def close(self):
        '''Closes the asset.'''
        assert(self.client and self.handle)
        self.client._closeAsset(self.handle)

    def onStatusUpdate(self, status):
        '''Should probably be overridden in subclass to react to status-changes.'''
        pass

class AssetIterator(object):
    '''Helper to iterate some assets, trying to open them, and fire a callback for each
       asset. See exampel in __main__ part of module.'''
    def __init__(self, client, assets, callback, whenDone, parallel=10, timeout=DEFAULT_TIMEOUT):
        self.client = client
        self.assets = assets
        self.callback = callback
        self.whenDone = whenDone
        self.parallel = parallel
        self.requestCount = 0
        self.timeout = timeout
        self._request()

    def _request(self):
        while self.requestCount < self.parallel:
            try:
                key, hashIds = self.assets.next()
            except StopIteration:
                return

            asset = Asset()
            asset.key = key
            asset.onStatusUpdate = MethodType(self._gotResponse, asset, Asset)
            self.client.allocateHandle(asset)
            asset.bind(hashIds, self.timeout)

            self.requestCount += 1

    def _gotResponse(self, asset, status):
        Asset.onStatusUpdate(asset, status)
        result = self.callback(asset, status, asset.key)

        if not result:
            asset.close()

        self.requestCount -= 1
        self._request() # Request more, if needed

        if not self.requestCount:
            self.whenDone()

class ClientWrapper(protocol.ClientFactory):
    '''!Twisted-API! Twisted-factory wrapping a pre-constructed Client, and dispatching
    connection-events to the Client.
    '''
    def __init__(self, client):
        self.client = client
        self.protocol = lambda: client

    def clientConnectionFailed(self, connector, reason):
        self.client.onFailed(reason)

def b32decode(string):
    l = len(string)
    string = string + "="*(7-((l-1)%8)) # Pad with = for b32decodes:s pleasure
    return _b32decode(string, True)

def connectUNIX(sock, client):
    factory = ClientWrapper(client)
    reactor.connectUNIX(sock, factory)

if __name__ == '__main__':
    import sys

    class TestClient(Client):
        def __init__(self, assets):
            self.assets = assets

        def onStatusUpdate(self, asset, status, key):
            print "Asset status: %s, %s" % (key, message._STATUS.values_by_number[status.status].name)

        def onConnected(self):
            self.ai = AssetIterator(self, self.assets, self.onStatusUpdate, self.whenDone)

        def onDisconnected(self, reason):
            if not self.closed:
                print "Disconnected; '%s'" % reason
                try: reactor.stop()
                except: pass

        def onFailed(self, reason):
            print "Failed to connect to BitHorde; '%s'" % reason
            reactor.stop()

        def whenDone(self):
            self.close()
            reactor.stop()

    if len(sys.argv) > 1:
        assetIds = ((asset,{message.TREE_TIGER: b32decode(asset)}) for asset in sys.argv[1:])
        connectUNIX("/tmp/bithorde", TestClient(assetIds))
        reactor.run()
    else:
        print "Usage: %s <tiger tree hash: base32> ..." % sys.argv[0]

