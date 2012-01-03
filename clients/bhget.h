
#ifndef BHGET_H
#define BHGET_H

#include <Poco/Foundation.h>
#include <Poco/Util/Application.h>

class BHGet : public Poco::Util::Application {
public:
    void initialize();
    void defineOptions();

    int main(const std::vector<std::string>& args);
};

#endif

