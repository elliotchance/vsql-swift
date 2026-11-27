// vsql_swift.h declares what the VSQL target needs from CVSQL besides
// libvsql.h (see vsql.c).
#ifndef VSQL_SWIFT_H
#define VSQL_SWIFT_H

// vsql_swift_prepare_thread must be called on a thread before it calls a
// libvsql routine. On Linux, the garbage collector stops the other threads
// with signals, but the threads of Dispatch (and Swift concurrency) block all
// signals, so it unblocks the collector's signals (once for each thread).
void vsql_swift_prepare_thread(void);

#endif
