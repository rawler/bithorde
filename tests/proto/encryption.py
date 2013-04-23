#!/usr/bin/env python

import os

from bithordetest import message, BithordeD, TestConnection

class EncryptedConnection(TestConnection):
    def __init__(self, tgt):
        TestConnection.__init__(self, tgt)
        self.encryptor = None
        self.decryptor = None
    def fetch(self):
        upper = TestConnection.fetch(self)
        if self.decryptor:
            upper = self.decryptor.decrypt(upper)
        return upper
    def push(self, blob):
        if self.encryptor:
            blob = self.encryptor.encrypt(upper)
        return TestConnection.push(self, blob)

if __name__ == '__main__':
    import base64, hashlib, hmac, os
    key = os.urandom(32)
    challenge = os.urandom(32)
    bithorded = BithordeD(config={
        'server.name': 'test_server',
        'client.tester.key': base64.b64encode(key),
    })
    conn = EncryptedConnection(bithorded)
    conn.send(message.HandShake(name="tester", protoversion=2, challenge=challenge))
    greeting = conn.expect(message.HandShake(name="test_server", protoversion=2))
    my_auth = hmac.HMAC(key, greeting.challenge + '\x00', digestmod=hashlib.sha256).digest()
    conn.send(message.HandShakeConfirmed(cipher=0, authentication = my_auth))

    expected_auth = hmac.new(key, challenge + '\x00', hashlib.sha256).digest()
    authentication = conn.expect(message.HandShakeConfirmed(authentication=expected_auth))
