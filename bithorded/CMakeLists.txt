
ADD_EXECUTABLE(bithorded
	lib/threadpool.cpp lib/threadpool.hpp
	lib/hashtree.cpp lib/hashtree.hpp
	lib/randomaccessfile.cpp lib/randomaccessfile.hpp
	lib/treestore.cpp lib/treestore.hpp

	store/asset.cpp store/asset.hpp
	store/assetmeta.cpp store/assetmeta.hpp

	main.cpp
)

TARGET_LINK_LIBRARIES(bithorded
	${Boost_LIBRARIES}
	bithorde
)
