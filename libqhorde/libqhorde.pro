#-------------------------------------------------
#
# Project created by QtCreator 2011-10-04T19:55:03
#
#-------------------------------------------------

QT       += network

QT       -= gui

TARGET = qhorde
TEMPLATE = lib

system(mkdir -p proto)
system(protoc ../bithorde.proto --proto_path=.. --cpp_out=proto)

DEFINES += LIBQHORDE_LIBRARY

SOURCES += proto/bithorde.pb.cc \
    asset.cpp \
    client.cpp \
    connection.cpp \
    hashes.cpp \
    cliprogressbar.cpp

HEADERS += libqhorde.h\
        libqhorde_global.h \
    asset.h \
    client.h \
    connection.h \
    hashes.h \
    cliprogressbar.h

unix:LIBS += -lprotobuf

symbian {
    #Symbian specific definitions
    MMP_RULES += EXPORTUNFROZEN
    TARGET.UID3 = 0xE5A4DA51
    TARGET.CAPABILITY = 
    TARGET.EPOCALLOWDLLDATA = 1
    addFiles.sources = libqhorde.dll
    addFiles.path = !:/sys/bin
    DEPLOYMENT += addFiles
}

unix:!symbian {
    maemo5 {
        target.path = /opt/usr/lib
    } else {
        target.path = /usr/local/lib
    }
    INSTALLS += target
}
