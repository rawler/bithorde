find_package(Protobuf REQUIRED)

function(PROTOBUF_GENERATE_PY MODS)
  if(NOT ARGN)
    message(SEND_ERROR "Error: PROTOBUF_GENERATE_CPP() called without any proto files")
    return()
  endif(NOT ARGN)

  set(_protobuf_include_path -I ${CMAKE_CURRENT_SOURCE_DIR})

  set(${MODS})
  foreach(FIL ${ARGN})
    get_filename_component(ABS_FIL ${FIL} ABSOLUTE)
    get_filename_component(FIL_WE ${FIL} NAME_WE)

    list(APPEND ${MODS} "${CMAKE_CURRENT_BINARY_DIR}/${FIL_WE}_pb2.py")

    add_custom_command(
      OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/${FIL_WE}_pb2.py"
      COMMAND  ${PROTOBUF_PROTOC_EXECUTABLE}
      ARGS --python_out  ${CMAKE_CURRENT_BINARY_DIR} ${_protobuf_include_path} ${ABS_FIL}
      DEPENDS ${ABS_FIL}
      COMMENT "Running Python protocol buffer compiler on ${FIL}"
      VERBATIM )
  endforeach()

  set_source_files_properties(${${MODS}} PROPERTIES GENERATED TRUE)
  set(${MODS} ${${MODS}} PARENT_SCOPE)
endfunction()


# Find the protoc Executable
find_program(PROTOBUF_PROTOC_PY_EXECUTABLE
    NAMES protoc
    DOC "The Google Protocol Buffers Python Compiler"
    PATHS
    ${PROTOBUF_SRC_ROOT_FOLDER}/vsprojects/Release
    ${PROTOBUF_SRC_ROOT_FOLDER}/vsprojects/Debug
)
mark_as_advanced(PROTOBUF_PROTOC_PY_EXECUTABLE)
