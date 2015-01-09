INCLUDE_DIRECTORIES (${PROTOC_OUT_DIR}) # For generated protobuf headers.

ADD_EXECUTABLE(bithorded
	cache/asset.cpp
	cache/manager.cpp

	http_server/connection.cpp
	http_server/connection_manager.cpp
	http_server/reply.cpp
	http_server/request.cpp
	http_server/request_handler.cpp
	http_server/request_parser.cpp
	http_server/server.cpp

	lib/assetsessions.cpp
	lib/grandcentraldispatch.cpp
	lib/hashtree.cpp
	lib/management.cpp
	lib/randomaccessfile.cpp
	lib/relativepath.cpp
	lib/rounding.cpp
	lib/subscribable.cpp
	lib/treestore.cpp

	router/asset.cpp
	router/router.cpp

	server/asset.cpp
	server/client.cpp
	server/config.cpp
	server/server.cpp

	source/asset.cpp
	source/store.cpp

	store/asset.cpp
	store/assetindex.cpp
	store/assetstore.cpp
	store/hashstore.cpp

	main.cpp

	${BitHorde_BINARY_DIR}/buildconf.cpp
)

TARGET_LINK_LIBRARIES(bithorded
	${Boost_LIBRARIES}
	${LOG4CPLUS_LIBRARIES}
	bithorde
)

# Install client-programs
INSTALL(TARGETS
	bithorded
	RUNTIME DESTINATION bin
)
