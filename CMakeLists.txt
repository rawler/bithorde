PROJECT (BitHorde)

CMAKE_MINIMUM_REQUIRED(VERSION 2.8)
SET(RELEASE_VERSION "0.3-preview1")

SET (EXECUTABLE_OUTPUT_PATH ${PROJECT_BINARY_DIR}/bin CACHE PATH
   "Single output directory for building all executables.")

# Setup CMAKE
set(CMAKE_MODULE_PATH ${CMAKE_SOURCE_DIR}/cmake)

# Read out git-version from Git.
include(GetGitRevisionDescription)
git_describe(BUILD_VERSION --dirty=-modified)
if(NOT DEFINED BUILD_VERSION)
  set(BUILD_VERSION RELEASE_VERSION)
endif(NOT DEFINED BUILD_VERSION)
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/buildconf.cpp.in" "${CMAKE_CURRENT_BINARY_DIR}/buildconf.cpp" @ONLY)

#-----------------------------------------------------------------------------
# Let's use the highest warning level.
#-----------------------------------------------------------------------------
IF(CMAKE_BUILD_TOOL MATCHES "(msdev|devenv|nmake)")
  # Use the highest warning level for visual studio.
  IF(CMAKE_CXX_FLAGS MATCHES "/W[0-4]")
    STRING(REGEX REPLACE "/W[0-4]" "/W4" CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}")
  ELSE(CMAKE_CXX_FLAGS MATCHES "/W[0-4]")
    SET(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} /W4")
  ENDIF(CMAKE_CXX_FLAGS MATCHES "/W[0-4]")
  IF(CMAKE_C_FLAGS MATCHES "/W[0-4]")
    STRING(REGEX REPLACE "/W[0-4]" "/W4" CMAKE_C_FLAGS "${CMAKE_C_FLAGS}")
  ELSE(CMAKE_C_FLAGS MATCHES "/W[0-4]")
    SET(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} /W4")
  ENDIF(CMAKE_C_FLAGS MATCHES "/W[0-4]")
  # Disable deprecation warnings for standard C functions in VS2005 and later
  IF(CMAKE_COMPILER_2005)
    ADD_DEFINITIONS(-D_CRT_SECURE_NO_DEPRECATE -D_CRT_NONSTDC_NO_DEPRECATE)
  ENDIF(CMAKE_COMPILER_2005)
ENDIF(CMAKE_BUILD_TOOL MATCHES "(msdev|devenv|nmake)")
IF(CMAKE_BUILD_TOOL MATCHES "make")
  IF(NOT CMAKE_CXX_FLAGS MATCHES "-Wall")
    SET(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall")
  ENDIF(NOT CMAKE_CXX_FLAGS MATCHES "-Wall")
  IF(NOT CMAKE_C_FLAGS MATCHES "-Wall")
    SET(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -Wall")
  ENDIF(NOT CMAKE_C_FLAGS MATCHES "-Wall")
ENDIF(CMAKE_BUILD_TOOL MATCHES "make")

IF("${CMAKE_CXX_COMPILER_ID}" MATCHES "clang")
  SET(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++0x -stdlib=libc++")
  SET(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -stdlib=libc++")
  SET(CMAKE_MODULE_LINKER_FLAGS "${CMAKE_MODULE_LINKER_FLAGS} -stdlib=libc++")
  SET(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -stdlib=libc++")
ELSEIF("${CMAKE_CXX_COMPILER_ID}" MATCHES "GNU")
  SET(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++0x")
ELSE()
  MESSAGE(FATAL_ERROR "Compiler requires config for C++0x in CMakeLists.txt")
ENDIF()

ADD_DEFINITIONS(-D_FILE_OFFSET_BITS=64)

set(Boost_USE_STATIC_LIBS        ON)
set(Boost_USE_MULTITHREADED      ON)
set(Boost_USE_STATIC_RUNTIME    OFF)
find_package( Boost REQUIRED COMPONENTS filesystem iostreams program_options regex signals system thread unit_test_framework )
if(Boost_FOUND)
	include_directories(${Boost_INCLUDE_DIRS})
endif()

INCLUDE_DIRECTORIES (${CMAKE_SOURCE_DIR})

# Setup protocol buffers
FIND_PACKAGE(Protobuf REQUIRED)
INCLUDE_DIRECTORIES(${PROTOBUF_INCLUDE_DIRS} ${CMAKE_BINARY_DIR}/lib)

# Setup the logging package
FIND_PACKAGE(Log4cplus REQUIRED)
INCLUDE_DIRECTORIES(${LOG4CPLUS_INCLUDE_DIRS})

# Setup the crypto++ package
FIND_PACKAGE(CryptoPP REQUIRED)
INCLUDE_DIRECTORIES(${CRYPTOPP_INCLUDE_DIRS})


FIND_PACKAGE(PkgConfig REQUIRED)

ADD_SUBDIRECTORY(lib)
ADD_SUBDIRECTORY(clients)
ADD_SUBDIRECTORY(bithorded)
ADD_SUBDIRECTORY(tests)

# Config installation
set(CONF_INSTALL_DIR etc CACHE PATH "Where should config-template be installed?")
INSTALL(FILES template.config
  DESTINATION ${CONF_INSTALL_DIR}
  RENAME bithorde.conf
)

# Test Setup
ENABLE_TESTING()
ADD_TEST(NAME UnitTests COMMAND unittests)
SET_TESTS_PROPERTIES(UnitTests PROPERTIES TIMEOUT 60)

# CPack packaging
INCLUDE(InstallRequiredSystemLibraries)
SET(CPACK_PACKAGE_DESCRIPTION_SUMMARY "Caching friend2friend oriented content-distribution.")
SET(CPACK_PACKAGE_VENDOR "bithorde.org")
SET(CPACK_PACKAGE_DESCRIPTION_FILE "${CMAKE_CURRENT_SOURCE_DIR}/README")
SET(CPACK_RESOURCE_FILE_LICENSE "${CMAKE_CURRENT_SOURCE_DIR}/LICENSE")
SET(CPACK_PACKAGE_VERSION "${BUILD_VERSION}")
SET(CPACK_PACKAGE_INSTALL_DIRECTORY "bithorde-${CPACK_PACKAGE_VERSION}")
SET(CPACK_PACKAGE_EXECUTABLES "bhfuse" "bhget" "bhupload" "bithorded")
INCLUDE(CPack)
