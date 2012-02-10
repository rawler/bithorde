
IF(${PROTOBUF_FOUND})
	WRAP_PROTO_CPP(BITHORDE_PROTO ${CMAKE_SOURCE_DIR}/bithorde.proto)
ENDIF(${PROTOBUF_FOUND})

ADD_LIBRARY(bithorde
	${BITHORDE_PROTO}
	allocator.h
	asset.h asset.cpp
	bithorde.h
	client.h client.cpp
	cliprogressbar.h cliprogressbar.cpp
	connection.h connection.cpp
	hashes.h hashes.cpp
	magneturi.h magneturi.cpp
	types.h types.cpp
)

TARGET_LINK_LIBRARIES(bithorde
	${PROTOBUF_LIBRARY}

	pthread
	crypto++
)
