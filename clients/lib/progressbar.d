module clients.lib.progressbar;

import tango.time.Clock;
import tango.io.Stdout;

const auto updateInterval = TimeSpan.fromMillis(50);
const auto perfUpdateInterval = TimeSpan.fromMillis(500);

class ProgressBar {
private:
    ulong max;
    char[] prefix;
    char[] perfUnit;
    uint perfDivisor;

    Time startTime;
    Time lastUpdateTime;
    ulong currentPos;

    Time lastPerfUpdateTime;
    ulong lastPerfUpdatePos;
    ulong currentPerf;

    ushort lastProgressSize;
public:
    this (ulong max, char[] prefix = "", char[] perfUnit = "", uint perfDivisor = 1) {
        this.max = max;
        this.prefix = prefix;
        this.perfUnit = perfUnit;
        this.perfDivisor = perfDivisor;

        startTime = Clock.now;
        lastUpdateTime = Clock.now;
        lastPerfUpdateTime = Clock.now;
    }

    void update(ulong pos, bool forced = false) {
        auto now = Clock.now;
        if (((now - lastUpdateTime) > updateInterval) || forced) {
            lastUpdateTime = now;
            currentPos = pos;
            updatePerformanceNumbers(forced);
            draw();
        }
    }

    void finish(ulong pos) {
        currentPos = pos;
        lastPerfUpdatePos = 0;
        lastPerfUpdateTime = startTime;
        updatePerformanceNumbers(true);
        draw();
        Stderr.newline;
    }

    void draw() {
        auto bar = "------------------------------------------------------------";
        auto percent = (currentPos * 100) / max;
        auto barlen  = (currentPos * bar.length) / max;
        for (int i; i < barlen; i++)
            bar[i] = '*';

        auto currentPerf = this.currentPerf / perfDivisor;
        auto progressSize = Stderr.layout.convert(Stderr, "\x0D{}[{}] {}% {}{}/s", prefix, bar, percent, currentPerf, perfUnit);
        for (int i = progressSize; i < lastProgressSize; i++)
            Stderr(' ');
        lastProgressSize = progressSize;
        Stderr.flush;
    }
private:
    void updatePerformanceNumbers(bool forced = false) {
        auto now = Clock.now;

        auto perfWindow = now - lastPerfUpdateTime;
        if ((perfWindow > perfUpdateInterval) || forced) {
            currentPerf = ((currentPos - lastPerfUpdatePos) * 1000000) / perfWindow.micros;
            lastPerfUpdateTime = now;
            lastPerfUpdatePos = currentPos;
        }
    }
}