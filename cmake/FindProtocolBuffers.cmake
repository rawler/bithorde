# Try to find protocol buffers (protobuf)
#
# Use as FIND_PACKAGE(ProtocolBuffers)
#
#  PROTOBUF_FOUND - system has the protocol buffers library
#  PROTOBUF_INCLUDE_DIR - the zip include directory
#  PROTOBUF_LIBRARY - Link this to use the zip library
#  PROTOBUF_PROTOC_EXECUTABLE - executable protobuf compiler
#
# And the following command
#
#  WRAP_PROTO(VAR input1 input2 input3..)
#
# Which will run protoc on the input files and set VAR to the names of the created .cc files,
# ready to be added to ADD_EXECUTABLE/ADD_LIBRARY. E.g,
#
#  WRAP_PROTO(PROTO_SRC myproto.proto external.proto)
#  ADD_EXECUTABLE(server ${server_SRC} ${PROTO_SRC})
#
# Author: Esben Mose Hansen <esben at ange.dk>, (C) Ange Optimization ApS 2008
# Modified For Python By: Ulrik Mikaelsson (C) 2010
#
# Redistribution and use is allowed according to the terms of the BSD license.
# For details see the accompanying COPYING-CMAKE-SCRIPTS file.

IF (PROTOBUF_LIBRARY AND PROTOBUF_INCLUDE_DIR AND PROTOBUF_PROTOC_EXECUTABLE)
  # in cache already
  SET(PROTOBUF_FOUND TRUE)
ELSE (PROTOBUF_LIBRARY AND PROTOBUF_INCLUDE_DIR AND PROTOBUF_PROTOC_EXECUTABLE)
  INCLUDE(FindPackageHandleStandardArgs)

  IF (PROTOBUF_REQUIRE_CPP)
    FIND_PATH(PROTOBUF_INCLUDE_DIR stubs/common.h
      /usr/include/google/protobuf
    )

    FIND_LIBRARY(PROTOBUF_LIBRARY NAMES protobuf
      PATHS
      ${GNUWIN32_DIR}/lib
    )
    FIND_PACKAGE_HANDLE_STANDARD_ARGS(protobuf-cpp DEFAULT_MSG PROTOBUF_INCLUDE_DIR PROTOBUF_LIBRARY)
    # ensure that they are cached
    SET(PROTOBUF_INCLUDE_DIR ${PROTOBUF_INCLUDE_DIR} CACHE INTERNAL "The protocol buffers include path")
    SET(PROTOBUF_LIBRARY ${PROTOBUF_LIBRARY} CACHE INTERNAL "The libraries needed to use protocol buffers library")
  ENDIF (PROTOBUF_REQUIRE_CPP)

  FIND_PROGRAM(PROTOBUF_PROTOC_EXECUTABLE protoc)
  FIND_PACKAGE_HANDLE_STANDARD_ARGS(protobuf DEFAULT_MSG PROTOBUF_PROTOC_EXECUTABLE)

  # ensure that it is cached
  SET(PROTOBUF_PROTOC_EXECUTABLE ${PROTOBUF_PROTOC_EXECUTABLE} CACHE INTERNAL "The protocol buffers compiler")
ENDIF (PROTOBUF_LIBRARY AND PROTOBUF_INCLUDE_DIR AND PROTOBUF_PROTOC_EXECUTABLE)

IF (PROTOBUF_FOUND)
  SET(PROTOC_OUT_DIR ${CMAKE_CURRENT_BINARY_DIR})

  # Define the WRAP_PROTO_CPP function
  FUNCTION(WRAP_PROTO_CPP VAR)
    IF (NOT ARGN)
      MESSAGE(SEND_ERROR "Error: WRAP_PROTO called without any proto files")
      RETURN()
    ENDIF(NOT ARGN)

    SET(${VAR})
    FOREACH(FIL ${ARGN})
      GET_FILENAME_COMPONENT(ABS_FIL ${FIL} ABSOLUTE)
      GET_FILENAME_COMPONENT(FIL_PATH ${FIL} PATH)
      GET_FILENAME_COMPONENT(FIL_WE ${FIL} NAME_WE)
      LIST(APPEND ${VAR} "${PROTOC_OUT_DIR}/${FIL_WE}.pb.cc")
      LIST(APPEND INCL "${PROTOC_OUT_DIR}/${FIL_WE}.pb.h")

      ADD_CUSTOM_COMMAND(
        OUTPUT ${${VAR}} ${INCL}
        COMMAND  ${PROTOBUF_PROTOC_EXECUTABLE}
        ARGS --cpp_out  ${PROTOC_OUT_DIR} --proto_path ${FIL_PATH} ${ABS_FIL}
        MAIN_DEPENDENCY ${ABS_FIL}
        COMMENT "Running protocol buffer compiler on ${FIL}"
        VERBATIM )
    ENDFOREACH(FIL)

    INCLUDE_DIRECTORIES(${PROTOC_OUT_DIR})

    SET(${VAR} ${${VAR}} PARENT_SCOPE)
  ENDFUNCTION(WRAP_PROTO_CPP)

  # Define the WRAP_PROTO_PYTHON function
  FUNCTION(WRAP_PROTO_PYTHON VAR)
    IF (NOT ARGN)
      MESSAGE(SEND_ERROR "Error: WRAP_PROTO_PYTHON called without any proto files")
      RETURN()
    ENDIF(NOT ARGN)

    SET(${VAR})
    FOREACH(FIL ${ARGN})
      GET_FILENAME_COMPONENT(ABS_FIL ${FIL} ABSOLUTE)
      GET_FILENAME_COMPONENT(FIL_WE ${FIL} NAME_WE)
      LIST(APPEND ${VAR} "${PROTOC_OUT_DIR}/${FIL_WE}_pb2.py")

      ADD_CUSTOM_COMMAND(
        OUTPUT ${${VAR}}
        COMMAND  ${PROTOBUF_PROTOC_EXECUTABLE}
        ARGS --python_out  ${PROTOC_OUT_DIR} --proto_path ${CMAKE_CURRENT_SOURCE_DIR} ${ABS_FIL}
        DEPENDS ${ABS_FIL}
        COMMENT "Running protocol buffer compiler on ${FIL}"
        VERBATIM )

    ENDFOREACH(FIL)

    SET(${VAR} ${${VAR}} PARENT_SCOPE)

  ENDFUNCTION(WRAP_PROTO_PYTHON)
ENDIF(PROTOBUF_FOUND)
