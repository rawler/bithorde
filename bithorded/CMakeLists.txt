INCLUDE_DIRECTORIES (${PROTOC_OUT_DIR}) # For generated protobuf headers.

ADD_EXECUTABLE(bithorded

	lib/threadpool.cpp
	lib/hashtree.cpp
	lib/randomaccessfile.cpp
	lib/rounding.cpp
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
	store/assetmeta.cpp
	store/assetstore.cpp

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
