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
HEADERS += \
    main.h


win32:CONFIG(release, debug|release): LIBS += -L$$OUT_PWD/../../libqhorde/release/ -lqhorde
else:win32:CONFIG(debug, debug|release): LIBS += -L$$OUT_PWD/../../libqhorde/debug/ -lqhorde
else:symbian: LIBS += -lqhorde
else:unix: LIBS += -L$$OUT_PWD/../../libqhorde/ -lqhorde

INCLUDEPATH += $$PWD/../../libqhorde
DEPENDPATH += $$PWD/../../libqhorde
