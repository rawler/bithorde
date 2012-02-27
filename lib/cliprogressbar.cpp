#include "cliprogressbar.h"

using namespace std;

CLIProgressBar::CLIProgressBar(ostream & out) :
	_out(out),
	_progress(0.0f),
	_width(80)
{
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
	draw();
}

void CLIProgressBar::draw()
{
	int total = _width - 2;
	int stars = total * _progress;
	int dashes = total - stars;
	_out << "\r[" << string(stars, '*') << string(dashes, '-') << "]";
	_out.flush();
}

void CLIProgressBar::finish()
{
	setProgress(1.0);
	draw();
	_out << endl;
	_out.flush();
}


