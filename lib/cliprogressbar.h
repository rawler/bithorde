#ifndef BITHORDE_CLIPROGRESSBAR_H
#define BITHORDE_CLIPROGRESSBAR_H

#include <ostream>

class CLIProgressBar
{
	std::ostream & _out;
	float _progress;
	int _width;
public:
	explicit CLIProgressBar(std::ostream & out);

public:
	void setProgress(float val);
	void setWidth(int chars);
	void finish();

private:
	void draw();
	void tick();
};

#endif // BITHORDE_CLIPROGRESSBAR_H
