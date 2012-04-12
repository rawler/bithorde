INCLUDE_DIRECTORIES (${PROTOC_OUT_DIR}) # For generated protobuf headers.

ADD_EXECUTABLE(bithorded
	lib/threadpool.cpp lib/threadpool.hpp
	lib/hashtree.cpp lib/hashtree.hpp
	lib/randomaccessfile.cpp lib/randomaccessfile.hpp
	lib/treestore.cpp lib/treestore.hpp

	server/client.cpp server/client.hpp
	server/config.cpp server/config.hpp
	server/server.cpp server/server.hpp

	store/asset.cpp store/asset.hpp
	store/assetmeta.cpp store/assetmeta.hpp
	store/linkedassetstore.cpp store/linkedassetstore.hpp

	main.cpp

	${BitHorde_BINARY_DIR}/buildconf.cpp
)

TARGET_LINK_LIBRARIES(bithorded
	${Boost_LIBRARIES}
	bithorde
)
