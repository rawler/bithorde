#include "cliprogressbar.h"

CLIProgressBar::CLIProgressBar(QTextStream * out, QObject *parent) :
    QObject(parent),
    _out(out),
    _progress(0.0f),
    _width(80)
{
    connect(&_timer, SIGNAL(timeout()), SLOT(tick()));
    _timer.start(100);
}

void CLIProgressBar::setProgress(float val)
{
    _progress = val;
}

void CLIProgressBar::setWidth(int chars)
{
    _width = chars;
}

void CLIProgressBar::tick()
{
    emit update();
    draw();
}

void CLIProgressBar::draw()
{
    int total = _width - 2;
    int stars = total * _progress;
    int dashes = total - stars;
    *_out << "\r[" << QString(stars, '*') << QString(dashes, '-') << "]";
    _out->flush();
}

void CLIProgressBar::finish()
{
    _timer.stop();
    setProgress(1.0);
    draw();
    *_out << "\n";
    _out->flush();
}


