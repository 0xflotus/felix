#ifndef __FLX_DYNLINK_H__
#define __FLX_DYNLINK_H__
#ifndef FLX_RTL
#include "flx_rtl.hpp"
#include "flx_gc.hpp"
#endif
#include <string>
using namespace std;

// define dynamic library loader stuff, even for static linkage
// SPECS:
//
// FLX_DLSYM(lib,sym) accepts a library handle and an identifier.
//   It works for both static and dynamic linkage.
//   For dynamic linkage it converts the symbol to a string
//     and calls dlsym
//   For static linkage it just returns the provided symbol,
//     which should have been linked by the linker.
//     This will work for both static linkage AND for
//     load time dynamic linkage (but not run time linkage).
//
// FLX_SDLSYM(lib,string) accepts a library handle
//   and a string. It should work run time linkage only.
//
// DLSYM(lib,sym) is just FLX_DLSYM, it requires a symbol.
//
// SDLSYM(lib,string) uses FLX_SDLSYM if dynamic linkage is selected 
//   and throws an exception if static linkage is chosen.
//
// Therefore: 
//   * the "S" version of these macros uses a string name,
//     the non-"S" version uses an identifier.
//
//   * FLX_SDLSYM uses a string name and always does
//     run time lookup.
//
//   * DLSYM uses a symbol and uses a linker bound
//     address if FLX_STATIC_LINK is selected
//     Otherwise it uses run time lookup.
//
#if FLX_WIN32
  #include <windows.h>
  typedef HMODULE LIBHANDLE;
  #define FLX_SET_NOLIBRARY(lib) lib=NULL
  #define FLX_CHECK_NOLIBRARY(lib) (lib==NULL)
  #define FLX_LIB_EXTENSION ".DLL"
  #define FLX_DLSYM(x,y) (void*)GetProcAddress(x,#y)
  #define FLX_SDLSYM(x,y) (void*)GetProcAddress(x,y)
#elif FLX_MACOSX_NODLCOMPAT
  #include <sys/stat.h>
  #include <mach-o/dyld.h>
  typedef NSModule LIBHANDLE;
  #define FLX_SET_NOLIBRARY(lib) lib=NULL
  #define FLX_CHECK_NOLIBRARY(lib) (lib==NULL)
  // using .so = bundle = programmatically loadable, unbreaks the 10.2 build
  // I'm not sure why the 10.3 and upwards versions of flx_load_module
  // work with .dylib, they really shouldn't shouldn't.
  // #define FLX_LIB_EXTENSION ".dylib"
  #define FLX_LIB_EXTENSION ".so"
  #define FLX_DLSYM(x, y) ::flx::rtl::getmachosym(x,"_"#y)
  #define FLX_SDLSYM(x, y) ::flx::rtl::getmachosym(x,(string("_")+string(y)).c_str())
#else
  // UNIX, recent OSX
  typedef void *LIBHANDLE;
  #define FLX_SET_NOLIBRARY(lib) lib=NULL
  #define FLX_CHECK_NOLIBRARY(lib) (lib==NULL)
  #if FLX_CYGWIN
    #define FLX_LIB_EXTENSION ".dll"
  #elif FLX_MACOSX
    // this should never have worked. dylibs can't be programmatically
    // loaded. perhaps 10.3 and above removed the bundle/dylib distinction.
     #define FLX_LIB_EXTENSION ".dylib"
    //#define FLX_LIB_EXTENSION ".so"
  #else
    #define FLX_LIB_EXTENSION ".so"
  #endif
  #include <dlfcn.h>
  #define FLX_DLSYM(x,y) dlsym(x,#y)
  #define FLX_SDLSYM(x,y) dlsym(x,y)
#endif

#define DLSYM(x,y) FLX_DLSYM(x,y)

#ifndef FLX_STATIC_LINK
  #define SDLSYM(x,y) FLX_SDLSYM(x,(y))
#else
  #define SDLSYM(x,y) (throw ::flx::rtl::flx_link_failure_t("<static link>",y,"dlsym with static link requires name not string"),(void*)0)
#endif

// Utilities to make dynamic linkage and
// initialisation of Felix modules easier
//
// We provide a standard exception to report
// link failure (missing symbol).
//
// We provide a class flx_dynlink_t which
// opens a Felix shared library given a filename,
// and links the mandatory symbols
// The user may derive from this class to add
// linkage for extra symbols
//
// We provide a class flx_libinit_t which
// initialises and terminates a Felix module
// The user may derive from this class to add
// extra initialisation or termination processing.
//
// [Note: the virtuals are *deliberately* private.
// Be sure to make your overrides private too,
// so they cannot be called:
// they're dispatched automatically by wrappers
// defined in the base]

// must be at global scope, because the users' is
namespace flx { namespace rtl {

struct RTL_EXTERN flx_link_failure_t;
struct RTL_EXTERN flx_dynlink_t;
struct RTL_EXTERN flx_libinit_t;

/// Dynamic linkage failure.

struct RTL_EXTERN flx_link_failure_t : flx_exception_t {
  string filename;
  string operation;
  string what;
  flx_link_failure_t(string f, string o, string w);
  virtual ~flx_link_failure_t();
};

RTL_EXTERN LIBHANDLE
flx_load_library(const std::string& filename);

RTL_EXTERN LIBHANDLE
flx_load_module(const std::string& filename);

/// frame creators.

typedef void *(*thread_frame_creator_t)
(
  ::flx::gc::generic::gc_profile_t*
);

/// library initialisation routine.

typedef con_t *(*start_t)
(
  void*,
  int,
  char **,
  FILE*,
  FILE*,
  FILE*

);

typedef con_t *(*main_t)(void*);

/// dynamic object loader.

struct RTL_EXTERN flx_dynlink_t
{
  // data
  LIBHANDLE library;
  thread_frame_creator_t thread_frame_creator;
  start_t start_sym;
  main_t main_sym;
  long refcnt;

  flx_dynlink_t();
  flx_dynlink_t(
    thread_frame_creator_t thread_frame_creator,
    start_t start_sym,
    main_t main_sym) throw(flx_link_failure_t);

  // routines
  void link(const std::string& filename) throw(flx_link_failure_t);
  void unlink();
  virtual ~flx_dynlink_t();

private:
  // the user should override this procedure to
  // link any extra symbols.
  // on error, throw a flx_link_failure_t,
  // otherwise your exception will be dishonoured
  // and a generic link_failure_t thrown anyhow

  flx_dynlink_t(flx_dynlink_t const&); // uncopyable
  void operator=(flx_dynlink_t const&); // uncopyable
  virtual void usr_link();
    // called after mandatory symbols are linked
};

/// Thread Frame Initialisation.

struct RTL_EXTERN flx_libinit_t
{
  void *thread_frame;
  con_t *start_proc;
  con_t *main_proc;
  flx_dynlink_t *lib;
  ::flx::gc::generic::gc_profile_t *gcp;
  void create
  (
    flx_dynlink_t *lib_a,
    ::flx::gc::generic::gc_profile_t *gcp_a,
    main_t main_sym,
    int argc,
    char **argv,
    FILE *stdin_,
    FILE *stdout_,
    FILE *stderr_
  );

  void destroy ();

  con_t *bind_proc(void *fn, void *data);
  virtual ~flx_libinit_t();
  flx_libinit_t();

private:
  flx_libinit_t(flx_libinit_t const&);
  void operator=(flx_libinit_t const&);
  // the user can override these procedures
  // to perform any additional initialisation
  // and termination required.

  virtual void usr_create();
    // called after standard init completes

  virtual void usr_destroy();
    // called before standard destroy starts
};

#if FLX_MACOSX_NODLCOMPAT
void* getmachosym(LIBHANDLE, const char*);
#endif

}} // namespaces
#endif
