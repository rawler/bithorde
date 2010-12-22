############################# BitHorde CMake Definitions #############################
cmake_minimum_required(VERSION 2.6)

project (BitHorde)

# Init D-stuff
set(CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)
FIND_PACKAGE(D REQUIRED)

set(D_DEBUG_KEYS "" CACHE STRING "Special debug-keywords to build with.")
add_d_debugs(${D_DEBUG_KEYS})

# The Bithorde daemon itself
add_d_program(bithorded daemon/bithorded.d)

# The client apps
add_d_program(bhget clients/bhget.d)
add_d_program(bhupload clients/bhupload.d)
add_d_program(bhfuse clients/bhfuse.d LIBS fuse)

# Install specifications
INSTALL(FILES
  ${CMAKE_CURRENT_BINARY_DIR}/bin/bithorded
  ${CMAKE_CURRENT_BINARY_DIR}/bin/bhget
  ${CMAKE_CURRENT_BINARY_DIR}/bin/bhupload
  ${CMAKE_CURRENT_BINARY_DIR}/bin/bhfuse
  DESTINATION bin
)

set(CONF_INSTALL_DIR etc CACHE PATH "Where should config-template be installed?")

INSTALL(FILES template.config
  DESTINATION ${CONF_INSTALL_DIR}
  RENAME bithorde.conf
)

# Tests
add_d_program(bithordelib tests/bithordelib.d OUTPUT_PATH ${CMAKE_CURRENT_BINARY_DIR}/tests)
add_d_program(protobuf tests/protobuf.d OUTPUT_PATH ${CMAKE_CURRENT_BINARY_DIR}/tests)
add_d_program(cachemap tests/cachemap.d OUTPUT_PATH ${CMAKE_CURRENT_BINARY_DIR}/tests)

ENABLE_TESTING()
ADD_TEST(RoundtripTest ${CMAKE_SOURCE_DIR}/tests/roundtrip/test_roundtrip.sh)
SET_TESTS_PROPERTIES(RoundtripTest PROPERTIES TIMEOUT 60 ENVIRONMENT "BH_BINDIR=${CMAKE_CURRENT_BINARY_DIR}/bin")

ADD_TEST(BithordeLibTest ${CMAKE_CURRENT_BINARY_DIR}/tests/bithordelib)
SET_TESTS_PROPERTIES(BithordeLibTest PROPERTIES TIMEOUT 60)

ADD_TEST(ProtoBuf ${CMAKE_CURRENT_BINARY_DIR}/tests/protobuf)
ADD_TEST(CacheMap ${CMAKE_CURRENT_BINARY_DIR}/tests/cachemap)

# CPack packaging
INCLUDE(InstallRequiredSystemLibraries)
SET(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Caching friend2friend oriented content-distribution.")
SET(CPACK_PACKAGE_VENDOR "bithorde.org")
SET(CPACK_PACKAGE_DESCRIPTION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/README")
SET(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")
SET(CPACK_PACKAGE_VERSION "0.1")
SET(CPACK_PACKAGE_INSTALL_DIRECTORY "bithorde-${CPACK_PACKAGE_VERSION}")
SET(CPACK_PACKAGE_EXECUTABLES "bhfuse" "bhget" "bhupload" "bithorded")
INCLUDE(CPack)

