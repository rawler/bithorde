
PROTOBUF_GENERATE_CPP(PROTO_SRCS PROTO_HDRS ${CMAKE_SOURCE_DIR}/bithorde.proto)

ADD_LIBRARY(bithorde
	${PROTO_HDRS} ${PROTO_SRCS}
	allocator.h
	asset.h asset.cpp
	bithorde.h
	client.h client.cpp
	cliprogressbar.h cliprogressbar.cpp
	counter.cpp
	connection.h connection.cpp
	hashes.h hashes.cpp
	magneturi.h magneturi.cpp
	random.h random.cpp
	timer.cpp
	types.h types.cpp
)

TARGET_LINK_LIBRARIES(bithorde
	${PROTOBUF_LIBRARIES}
	${Boost_LIBRARIES}
	${Boost_LIBRARY_DEPENDENCIES}
	${CRYPTOPP_LIBRARIES}

	pthread
)
