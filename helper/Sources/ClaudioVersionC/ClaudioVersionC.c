#include "ClaudioVersionC.h"

#ifndef CLAUDIO_VERSION
#error "CLAUDIO_VERSION must be supplied by Package.swift"
#endif

const char *claudio_build_version(void) {
    return CLAUDIO_VERSION;
}
