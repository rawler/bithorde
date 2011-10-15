#-------------------------------------------------
#
# Project created by QtCreator 2011-10-15T16:33:41
#
#-------------------------------------------------

QT       += core network

QT       -= gui

TARGET = bhget
CONFIG   += console
CONFIG   -= app_bundle

TEMPLATE = app


SOURCES += main.cpp
HEADERS += \
    main.h

win32:CONFIG(release, debug|release): LIBS += -L$$OUT_PWD/../../libqhorde/release/ -lqhorde
else:win32:CONFIG(debug, debug|release): LIBS += -L$$OUT_PWD/../../libqhorde/debug/ -lqhorde
else:symbian: LIBS += -lqhorde
else:unix: LIBS += -L$$OUT_PWD/../../libqhorde/ -lqhorde

INCLUDEPATH += $$PWD/../../libqhorde
DEPENDPATH += $$PWD/../../libqhorde

unix:LIBS += -lprotobuf -lcrypto++
