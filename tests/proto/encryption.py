#!/usr/bin/env python

import os
from struct import pack

from bithordetest import message, BithordeD, TestConnection

class EncryptedConnection(TestConnection):
    def __init__(self, tgt):
        TestConnection.__init__(self, tgt)
        self.encryptor = None
        self.decryptor = None
    def fetch(self):
        upper = TestConnection.fetch(self)
        if self.decryptor:
            upper = self.decryptor(upper)
        return upper
    def push(self, blob):
        if self.encryptor:
            blob = self.encryptor(blob)
        return TestConnection.push(self, blob)

class Counter:
    def __init__(self, iv):
        self._block = [ord(c) for c in iv]
    def __call__(self):
        res = pack("B"*len(self._block), *self._block)
        idx = len(self._block)-1
        while idx >= 0:
            current = self._block[idx] + 1
            self._block[idx] = current
            if current == 0:
                idx -= 1
            else:
                break
        return res

if __name__ == '__main__':
    import base64, hashlib, hmac, os
    from Crypto.Cipher import AES, ARC4
    key = os.urandom(16)
    sendIv = os.urandom(16)
    challenge = os.urandom(32)
    bithorded = BithordeD(config={
        'server.name': 'test_server',
        'client.tester': {
            'cipher': 'RC4',
            'key': base64.b64encode(key),
        },
    })
    conn = EncryptedConnection(bithorded)
    conn.send(message.HandShake(name="tester", protoversion=2, challenge=challenge))
    greeting = conn.expect(message.HandShake(name="test_server", protoversion=2))
    my_auth = hmac.HMAC(key, greeting.challenge + '\x03' + sendIv, digestmod=hashlib.sha256).digest()
    conn.send(message.HandShakeConfirmed(cipher=message.AES_CTR, cipheriv=sendIv, authentication = my_auth))

    authentication = conn.expect(message.HandShakeConfirmed(cipher=message.RC4))
    expected_auth = hmac.new(key, challenge + '\x02' + authentication.cipheriv, hashlib.sha256).digest()
    assert authentication.authentication == expected_auth

    conn.encryptor = AES.new(key, AES.MODE_CTR, counter=Counter(sendIv)).encrypt
    conn.decryptor = ARC4.new(hmac.HMAC(key, authentication.cipheriv, digestmod=hashlib.sha256).digest()).decrypt

    conn.send(message.Ping(timeout=2000))
    conn.expect(message.Ping)
