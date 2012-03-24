
INCLUDE_DIRECTORIES (${BitHorde_SOURCE_DIR})
LINK_DIRECTORIES (${BitHorde_BINARY_DIR}/lib)

ADD_EXECUTABLE(bhget
	bhget.cpp bhget.h
)

TARGET_LINK_LIBRARIES ( bhget
	${Boost_LIBRARIES}
	bithorde
)

ADD_EXECUTABLE(bhupload
	bhupload.cpp bhupload.h
)
TARGET_LINK_LIBRARIES ( bhupload
	${Boost_LIBRARIES}
	bithorde
)

PKG_CHECK_MODULES (FUSE REQUIRED fuse)

ADD_EXECUTABLE(bhfuse
	bhfuse/fuse++.cpp bhfuse/fuse++.hpp
	bhfuse/inode.cpp bhfuse/inode.h
	bhfuse/lookup.cpp bhfuse/lookup.h
	bhfuse/main.cpp bhfuse/main.h
)

STRING(REPLACE ";" " " FUSE_FLAG_STRING "${FUSE_CFLAGS}")
SET_TARGET_PROPERTIES(bhfuse PROPERTIES
	COMPILE_FLAGS "${FUSE_FLAG_STRING}"
)
TARGET_LINK_LIBRARIES ( bhfuse
	${Boost_LIBRARIES}
	${FUSE_LIBRARIES}
	bithorde
)
