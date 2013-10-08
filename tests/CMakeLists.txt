
ADD_EXECUTABLE( unittests
	test_main.cpp
	../bithorded/lib/randomaccessfile.cpp
	../bithorded/lib/hashtree.cpp test_hashtree.cpp
	../bithorded/lib/rounding.cpp test_rounding.cpp
	../lib/timer.cpp test_timer.cpp
	../lib/connection.cpp test_message_queue.cpp
	../bithorded/lib/treestore.cpp test_treestore.cpp
	../bithorded/store/assetmeta.cpp test_assetmeta.cpp
)

TARGET_LINK_LIBRARIES( unittests
	bithorde
	${Boost_LIBRARIES}
)
