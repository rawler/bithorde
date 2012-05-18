INCLUDE_DIRECTORIES (${PROTOC_OUT_DIR}) # For generated protobuf headers.

ADD_EXECUTABLE(bithorded
	lib/threadpool.cpp lib/threadpool.hpp
	lib/hashtree.cpp lib/hashtree.hpp
	lib/randomaccessfile.cpp lib/randomaccessfile.hpp
	lib/treestore.cpp lib/treestore.hpp

	router/asset.cpp router/asset.hpp
	router/router.cpp router/router.hpp

	server/asset.cpp server/asset.hpp
	server/client.cpp server/client.hpp
	server/config.cpp server/config.hpp
	server/server.cpp server/server.hpp

	store/sourceasset.cpp store/sourceasset.hpp
	store/assetmeta.cpp store/assetmeta.hpp
	store/linkedassetstore.cpp store/linkedassetstore.hpp

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
