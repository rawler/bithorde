#!/usr/bin/env python

import os, socket
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

def setupCipher(type, key, iv):
    if type == message.AES_CTR:
        return AES.new(key, AES.MODE_CTR, counter=Counter(iv))
    elif type == message.RC4:
        return ARC4.new(hmac.HMAC(key, iv, digestmod=hashlib.sha256).digest())
    else:
        raise RuntimeError("Unsupported Cipher" + type)

def secure_auth_and_encryption(conn, name, key, cipher, validate_auth=True):
    sendIv = os.urandom(16)
    challenge = os.urandom(32)

    try:
        conn.send(message.HandShake(name=name, protoversion=2, challenge=challenge))
        greeting = conn.expect(message.HandShake(protoversion=2))
        my_auth = hmac.HMAC(key, greeting.challenge + chr(cipher) + sendIv, digestmod=hashlib.sha256).digest()
        conn.send(message.HandShakeConfirmed(cipher=cipher, cipheriv=sendIv, authentication = my_auth))

        authentication = conn.expect(message.HandShakeConfirmed)
        expected_auth = hmac.new(key, challenge + chr(authentication.cipher) + authentication.cipheriv, hashlib.sha256).digest()
        if validate_auth:
            assert authentication.authentication == expected_auth

        conn.encryptor = setupCipher(cipher, key, sendIv).encrypt
        conn.decryptor = setupCipher(authentication.cipher, key, authentication.cipheriv).decrypt
    except (socket.error, StopIteration):
        return None
    return greeting.name

if __name__ == '__main__':
    import base64, hashlib, hmac
    from Crypto.Cipher import AES, ARC4
    key = os.urandom(16)
    bithorded = BithordeD(config={
        'server.name': 'test_server',
        'client.tester1': {
            'cipher': 'RC4',
            'key': base64.b64encode(key),
        },
        'client.tester2': {
            'cipher': 'AES',
            'key': base64.b64encode(key),
        },
    })

    # Test auth failure for unknown key
    conn = EncryptedConnection(bithorded)
    assert secure_auth_and_encryption(conn, name="anonymous", key=key, cipher=message.RC4) == None

    # Test auth failure for wrong key
    conn = EncryptedConnection(bithorded)
    secure_auth_and_encryption(conn, name="tester1", key='0'*len(key), cipher=message.RC4, validate_auth=False)

    try:
        conn.send(message.Ping(timeout=2000))
        conn.expect(message.Ping)
        assert False, "We really should not have gotten here"
    except:
        pass

    # Test successful AES upstream / RC4 downstream
    conn = EncryptedConnection(bithorded)
    assert secure_auth_and_encryption(conn, name="tester1", key=key, cipher=message.AES_CTR) == 'test_server'

    conn.send(message.Ping(timeout=2000))
    conn.expect(message.Ping)
    conn.close()

    # Test successful RC4 upstream / AES downstream
    conn = EncryptedConnection(bithorded)
    assert secure_auth_and_encryption(conn, name="tester2", key=key, cipher=message.RC4) == 'test_server'

    conn.send(message.Ping(timeout=2000))
    conn.expect(message.Ping)
    conn.close()

    assert bithorded.is_alive()