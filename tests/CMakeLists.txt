
ADD_EXECUTABLE( unittests 
	../bithorded/lib/treestore.cpp test_treestore.cpp
	../bithorded/lib/hashtree.cpp test_hashtree.cpp
)

TARGET_LINK_LIBRARIES( unittests
	${Boost_LIBRARIES}
	bithorde
)