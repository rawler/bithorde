
ADD_EXECUTABLE( unittests
	test_main.cpp
	../bithorded/lib/randomaccessfile.cpp
	../bithorded/lib/hashtree.cpp test_hashtree.cpp
	../bithorded/lib/rounding.cpp test_rounding.cpp
	../bithorded/lib/subscribable.cpp test_subscribable.cpp
	../lib/timer.cpp test_timer.cpp
	../lib/connection.cpp test_message_queue.cpp
	../bithorded/lib/treestore.cpp test_treestore.cpp
	../bithorded/store/hashstore.cpp test_hashstore.cpp

	../bithorded/lib/assetsessions.cpp ../bithorded/lib/relativepath.cpp
	../bithorded/lib/grandcentraldispatch.cpp
	../bithorded/cache/asset.cpp ../bithorded/cache/manager.cpp
	../bithorded/source/asset.cpp ../bithorded/source/store.cpp
	../bithorded/store/asset.cpp ../bithorded/store/assetindex.cpp ../bithorded/store/assetstore.cpp
	../bithorded/server/asset.cpp ../bithorded/lib/management.cpp
	../bithorded/http_server/request.cpp ../bithorded/http_server/reply.cpp
	test_storedasset.cpp
)

TARGET_LINK_LIBRARIES( unittests
	bithorde
	${Boost_LIBRARIES}
	${LOG4CPLUS_LIBRARIES}
)
