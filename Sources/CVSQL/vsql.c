// libvsql, from the vsql amalgamation (see scripts/update-amalgamation.sh).
//
// The C that V generates causes many warnings, which are turned off here
// rather than with -w, since a package that's used as a dependency can't have
// unsafe flags. On Linux, it passes a pthread_t as a void*, which is an error
// (-Wint-conversion) unless it's turned off.
#pragma clang diagnostic ignored "-Weverything"
#pragma clang diagnostic ignored "-Wint-conversion"
#pragma clang diagnostic ignored "-Wincompatible-pointer-types"
#pragma clang diagnostic ignored "-Wincompatible-function-pointer-types"
#pragma clang diagnostic ignored "-Wimplicit-function-declaration"
#pragma clang diagnostic ignored "-Wimplicit-int"
#pragma clang diagnostic ignored "-Wreturn-type"

#if defined(__APPLE__) && __has_feature(modules)
// SwiftPM compiles C with clang modules on Apple platforms, so including any
// system header loads the whole Darwin module, and the declarations of every
// header in it (even the ones that libvsql doesn't include) conflict with
// libvsql's own:
//
// - vsql's scroll() has the same name as the one in curses.h, so it's renamed.
// - V and the garbage collector declare system functions themselves, with
//   other parameter types than the SDK's headers. Those declarations are
//   renamed, and declared first with an asm label of the real function, which
//   the renamed declarations inherit.
#include <sys/types.h>
#include <mach/mach.h>

#define scroll vsql_scroll
#define scroll_to vsql_scroll_to

#define VSQL_REAL(name) __asm__("_" #name)

#define posix_spawn vsql_posix_spawn
#define posix_spawnp vsql_posix_spawnp
#define posix_spawn_file_actions_init vsql_posix_spawn_file_actions_init
#define posix_spawn_file_actions_destroy vsql_posix_spawn_file_actions_destroy
#define posix_spawn_file_actions_adddup2 vsql_posix_spawn_file_actions_adddup2
#define posix_spawn_file_actions_addclose vsql_posix_spawn_file_actions_addclose
#define posix_spawnattr_init vsql_posix_spawnattr_init
#define posix_spawnattr_setflags vsql_posix_spawnattr_setflags
#define posix_spawnattr_destroy vsql_posix_spawnattr_destroy
extern int posix_spawn(pid_t *, const char *, const void *, const void *,
                       char *const[], char *const[]) VSQL_REAL(posix_spawn);
extern int posix_spawnp(pid_t *, const char *, const void *, const void *,
                        char *const[], char *const[]) VSQL_REAL(posix_spawnp);
extern int posix_spawn_file_actions_init(void *)
    VSQL_REAL(posix_spawn_file_actions_init);
extern int posix_spawn_file_actions_destroy(void *)
    VSQL_REAL(posix_spawn_file_actions_destroy);
extern int posix_spawn_file_actions_adddup2(void *, int, int)
    VSQL_REAL(posix_spawn_file_actions_adddup2);
extern int posix_spawn_file_actions_addclose(void *, int)
    VSQL_REAL(posix_spawn_file_actions_addclose);
extern int posix_spawnattr_init(void *) VSQL_REAL(posix_spawnattr_init);
extern int posix_spawnattr_setflags(void *, short)
    VSQL_REAL(posix_spawnattr_setflags);
extern int posix_spawnattr_destroy(void *) VSQL_REAL(posix_spawnattr_destroy);

#define exception_raise_state vsql_exception_raise_state
extern kern_return_t exception_raise_state(
    mach_port_t, mach_port_t, mach_port_t, exception_type_t, exception_data_t,
    mach_msg_type_number_t, thread_state_flavor_t *, thread_state_t,
    mach_msg_type_number_t, thread_state_t, mach_msg_type_number_t *)
    VSQL_REAL(exception_raise_state);
#endif

// The clang of Swift 6.2 crashes in instcombine (on Linux and Windows) when
// it optimizes the garbage collector's functions that push the collector's own
// roots (GC_PUSH_ALL_SYM). GC_push_all_eager isn't inlined into them, which is
// enough on Linux, and on Windows GC_push_thread_structures isn't optimized at
// all. The attributes of these declarations are inherited by the definitions.
void GC_push_all_eager(void *bottom, void *top) __attribute__((noinline));
static void GC_push_thread_structures(void) __attribute__((optnone, noinline));

#include "amalgamation/libvsql.c"

#include "vsql_swift.h"

#if defined(__linux__)
void vsql_swift_prepare_thread(void) {
  static __thread int prepared;
  if (prepared) {
    return;
  }
  prepared = 1;

  sigset_t signals;
  sigemptyset(&signals);
  sigaddset(&signals, GC_get_suspend_signal());
  sigaddset(&signals, GC_get_thr_restart_signal());
  pthread_sigmask(SIG_UNBLOCK, &signals, NULL);
}
#else
void vsql_swift_prepare_thread(void) {}
#endif
