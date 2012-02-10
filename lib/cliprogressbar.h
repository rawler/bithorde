#ifndef CLIPROGRESSBAR_H
#define CLIPROGRESSBAR_H

#include <iostream>

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

#endif // CLIPROGRESSBAR_H
