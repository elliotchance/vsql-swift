// The iOS SDK doesn't have sys/random.h, which libvsql includes for
// getentropy (which is in the iOS libSystem). See ../README.md.
#ifndef VSQL_IOS_SYS_RANDOM_H
#define VSQL_IOS_SYS_RANDOM_H

#include <stddef.h>

int getentropy(void *buffer, size_t size);

#endif
