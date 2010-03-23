module lib.arguments;

import tango.text.Arguments : _Arguments = Arguments;

/****************************************************************************************
 * Extended tango Arguments-parser with support for bool arguments
 ***************************************************************************************/
abstract class Arguments : protected _Arguments {
    const char[][] autoBool = ["auto", "yes", "no", "y", "n", "1", "0"];
public:
    bool getAutoBool(char[] name, bool delegate() autoCase) {
        auto v = this[name].assigned[0];
        if (v[0] == 'a')
            return autoCase();
        else
            return ((v[0] == 'y') || (v[0] == '1'));
    }
}