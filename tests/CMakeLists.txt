
ADD_EXECUTABLE( unittests
	test_main.cpp
	../bithorded/lib/hashtree.cpp test_hashtree.cpp
	../bithorded/lib/threadpool.cpp test_threadpool.cpp
	../bithorded/lib/treestore.cpp test_treestore.cpp
	../bithorded/store/assetmeta.cpp test_assetmeta.cpp
)

TARGET_LINK_LIBRARIES( unittests
	bithorde
	${Boost_LIBRARIES}
)