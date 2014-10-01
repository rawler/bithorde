# -*- coding: utf-8 -*-
'''
Python library for querying BitHorde nodes. Currently only implements opening and closing
assets. More to come later.

Twisted-based implementation.
'''

import socket
import os, os.path
from types import MethodType

import bithorde_pb2 as message

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
    message.HandShakeConfirmed: 9,
    message.Ping: 10,
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

