#ifndef LIBBITHORDE_H
#define LIBBITHORDE_H

#include "asset.h"
#include "client.h"
#include "hashes.h"
#include "magneturi.h"

const uint16_t    BITHORDED_DEFAULT_INSPECT_PORT = 5000;
const uint16_t    BITHORDED_DEFAULT_TCP_PORT     = 1337;
const std::string BITHORDED_DEFAULT_UNIX_SOCKET  = "/var/run/bithorde/socket";

#endif // LIBBITHORDE_H
