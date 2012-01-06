#ifndef CLIPROGRESSBAR_H
#define CLIPROGRESSBAR_H

#include <QObject>
#include <QtCore/QTextStream>
#include <QtCore/QTimer>

class CLIProgressBar : public QObject
{
    Q_OBJECT

    QTextStream * _out;
    QTimer _timer;
    float _progress;
    int _width;
public:
    explicit CLIProgressBar(QTextStream * out, QObject *parent = 0);

signals:
    void update();

public slots:
    void setProgress(float val);
    void setWidth(int chars);
    void finish();

private slots:
    void draw();
    void tick();
};

#endif // CLIPROGRESSBAR_H
