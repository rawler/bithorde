#-------------------------------------------------
#
# Project created by QtCreator 2011-10-17T21:02:33
#
#-------------------------------------------------

QT       += core network
QT       -= gui

CONFIG += link_pkgconfig
PKGCONFIG += fuse

TARGET = bhfuse

CONFIG   += console
CONFIG   -= app_bundle

TEMPLATE = app

SOURCES += main.cpp \
    qfilesystem.cpp \
    inode.cpp \
    lookup.cpp

HEADERS += \
    qfilesystem.h \
    main.h \
    inode.h \
    lookup.h

win32:CONFIG(release, debug|release): LIBS += -L$$OUT_PWD/../../libqhorde/release/ -lqhorde
else:win32:CONFIG(debug, debug|release): LIBS += -L$$OUT_PWD/../../libqhorde/debug/ -lqhorde
else:symbian: LIBS += -lqhorde
else:unix: LIBS += -L$$OUT_PWD/../../libqhorde/ -lqhorde

INCLUDEPATH += $$PWD/../../libqhorde
DEPENDPATH += $$PWD/../../libqhorde
