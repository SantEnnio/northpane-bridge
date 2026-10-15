#include "NorthpaneEmbeddedReader.h"

extern const unsigned char np_claude_reader_start[];
extern const unsigned char np_claude_reader_end[];

const unsigned char *np_claude_reader_data(void) { return np_claude_reader_start; }
size_t np_claude_reader_size(void) { return (size_t)(np_claude_reader_end - np_claude_reader_start); }

#if defined(__linux__) && defined(NORTHPANE_CLAUDE_READER_FILE)
extern const unsigned char np_reader_js_start[], np_reader_js_end[];
extern const unsigned char np_reader_musl_start[], np_reader_musl_end[];
extern const unsigned char np_reader_gcc_start[], np_reader_gcc_end[];
extern const unsigned char np_reader_cxx_start[], np_reader_cxx_end[];
const unsigned char *np_claude_reader_asset_data(int asset) {
    switch (asset) {
    case 0: return np_reader_js_start;
    case 1: return np_reader_musl_start;
    case 2: return np_reader_gcc_start;
    case 3: return np_reader_cxx_start;
    default: return NULL;
    }
}
size_t np_claude_reader_asset_size(int asset) {
    switch (asset) {
    case 0: return (size_t)(np_reader_js_end - np_reader_js_start);
    case 1: return (size_t)(np_reader_musl_end - np_reader_musl_start);
    case 2: return (size_t)(np_reader_gcc_end - np_reader_gcc_start);
    case 3: return (size_t)(np_reader_cxx_end - np_reader_cxx_start);
    default: return 0;
    }
}
#else
const unsigned char *np_claude_reader_asset_data(int asset) { return NULL; }
size_t np_claude_reader_asset_size(int asset) { return 0; }
#endif
