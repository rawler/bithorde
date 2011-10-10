#-------------------------------------------------
#
# Project created by QtCreator 2011-10-05T20:53:08
#
#-------------------------------------------------

QT       += core network

QT       -= gui

TARGET = bhupload
CONFIG   += console
CONFIG   -= app_bundle

TEMPLATE = app

unix:LIBS += -lprotobuf -lcrypto++

SOURCES += main.cpp

win32:CONFIG(release, debug|release): LIBS += -L$$PWD/../../libqhorde-build-desktop/ -lqhorde
else:win32:CONFIG(debug, debug|release): LIBS += -L$$PWD/../../libqhorde-build-desktop/ -lqhorde
else:symbian: LIBS += -llibqhorde
else:unix: LIBS += -L$$PWD/../../libqhorde-build-desktop/ -lqhorde

INCLUDEPATH += $$PWD/../../libqhorde
DEPENDPATH += $$PWD/../../libqhorde

HEADERS += \
    main.h
