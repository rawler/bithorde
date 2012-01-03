
ADD_EXECUTABLE(bhget bhget.cpp bhget.h)
TARGET_LINK_LIBRARIES ( bhget
  "optimized" PocoFoundation PocoUtil PocoNet
  "debug" PocoFoundationd PocoUtild PocoNetd
)
