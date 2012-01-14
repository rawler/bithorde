
INCLUDE_DIRECTORIES (${BitHorde_SOURCE_DIR})
INCLUDE_DIRECTORIES (${PROTOC_OUT_DIR}) # For generated protobuf headers.
LINK_DIRECTORIES (${BitHorde_BINARY_DIR}/lib)

ADD_EXECUTABLE(bhget
	bhget.cpp bhget.h
)
TARGET_LINK_LIBRARIES ( bhget
	"optimized" PocoFoundation PocoUtil PocoNet
	"debug" PocoFoundationd PocoUtild PocoNetd

	bithorde
)
