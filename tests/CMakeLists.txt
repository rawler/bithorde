
ADD_EXECUTABLE( unittests 
	../daemon/lib/treestore.cpp test_treestore.cpp
	../daemon/lib/hashtree.cpp test_hashtree.cpp
)

TARGET_LINK_LIBRARIES( unittests
	${Boost_LIBRARIES}
	bithorde
)