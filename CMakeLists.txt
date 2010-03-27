############################# BitHorde CMake Definitions #############################
cmake_minimum_required(VERSION 2.6)

project (BitHorde)

# Init D-stuff
set(CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)
FIND_PACKAGE(D REQUIRED)

# The Bithorde daemon itself
add_d_program(bithorded daemon/bithorded.d)

# The client apps
add_d_program(bhget clients/bhget.d)
add_d_program(bhupload clients/bhupload.d)
add_d_program(bhfuse clients/bhfuse.d LIBS fuse)

# Tests
add_d_program(bithordelib tests/bithordelib.d OUTPUT_PATH ${CMAKE_CURRENT_BINARY_DIR}/tests)
add_d_program(protobuf tests/protobuf.d OUTPUT_PATH ${CMAKE_CURRENT_BINARY_DIR}/tests)
