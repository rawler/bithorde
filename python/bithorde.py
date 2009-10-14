# -*- coding: utf-8 -*-

import socket
import os, os.path

import bithorde_pb2 as message
from google.protobuf import descriptor
from google.protobuf.internal import encoder,decoder

MESSAGES = message._STREAM.fields_by_name
message.HandShake.id = MESSAGES['handshake'].number
MSGMAP = {1: message.HandShake,
          }

class Client(object):
    def __init__(self, s):
        self.socket = s
        self.buf = ""
        handshake = message.HandShake()
        handshake.name = 'pyhorde'
        handshake.protoversion = 1
        self._send(handshake)

    def _send(self, msg):
        enc = encoder.Encoder()
        enc.AppendMessage(type(msg).id, msg)
        self.socket.send(enc.ToString())

    def _readMsg(self):
        dec = None
        buf = self.socket.recv(262144)
        self.buf += buf
        dec = decoder.Decoder(self.buf)
        id = dec.ReadUInt32() >> 3
        size = dec.ReadUInt32()
        msgstart = dec.Position()
        msgend = msgstart+size
        self.buf = self.buf[msgend:]

        obj = MSGMAP[id]()
        obj.ParseFromString(buf[msgstart:msgend])
        return obj

if __name__ == '__main__':
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect("/tmp/bithorde")
    c = Client(sock)
    print c._readMsg()