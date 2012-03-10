
ADD_EXECUTABLE( unittests 
	../daemon/lib/treestore.cpp test_treestore.cpp
)

TARGET_LINK_LIBRARIES( unittests
	${Boost_LIBRARIES}
)