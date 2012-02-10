
INCLUDE_DIRECTORIES (${BitHorde_SOURCE_DIR})
INCLUDE_DIRECTORIES (${PROTOC_OUT_DIR}) # For generated protobuf headers.
LINK_DIRECTORIES (${BitHorde_BINARY_DIR}/lib)

ADD_EXECUTABLE(bhget
	bhget.cpp bhget.h
)
message(STATUS APA ${Boost_LIBRARIES})
TARGET_LINK_LIBRARIES ( bhget
	${Boost_LIBRARIES}

	bithorde
)

ADD_EXECUTABLE(bhupload
	bhupload.cpp bhupload.h
)
TARGET_LINK_LIBRARIES ( bhupload
	${Boost_LIBRARIES}

	bithorde
)
