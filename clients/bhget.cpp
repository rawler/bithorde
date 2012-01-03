
#include "bhget.h"

void BHGet::initialize() {
}

void BHGet::defineOptions() {
}

int BHGet::main(const std::vector<std::string>& args) {
    return EXIT_OK;
}

int main(int argc, char *argv[]) {
    BHGet app;
    app.init(argc, argv);

    return app.run();
}
