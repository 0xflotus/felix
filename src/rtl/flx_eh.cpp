#include <stdio.h>
#include "flx_rtl.hpp"
#include "flx_dynlink.hpp"
#include "flx_exceptions.hpp"
#include "flx_eh.hpp"
using namespace ::flx::rtl;


int ::flx::rtl::std_exception_handler (std::exception *e)
{
  fprintf(stderr,"C++ STANDARD EXCEPTION %s\n",e->what());
  return 4;
}

int ::flx::rtl::flx_exception_handler (flx_exception_t *e)
{
  if (flx_halt_t *x = dynamic_cast<flx_halt_t*>(e))
  {
    fprintf(stderr,"Halt: %s \n",x->reason.data());
    print_loc(stderr,x->flx_loc,x->cxx_srcfile, x->cxx_srcline);
    return 3;
  }
  if (flx_link_failure_t *x = dynamic_cast<flx_link_failure_t*>(e))
  {
    fprintf(stderr,"Dynamic linkage error\n");
    fprintf(stderr,"filename: %s\n",x->filename.data());
    fprintf(stderr,"operation: %s\n",x->operation.data());
    fprintf(stderr,"what: %s\n",x->what.data());
    return 2;
  }
  else
  if (flx_exec_failure_t *x = dynamic_cast<flx_exec_failure_t*>(e))
  {
    fprintf(stderr,"Execution error\n");
    fprintf(stderr,"filename: %s\n",x->filename.data());
    fprintf(stderr,"operation: %s\n",x->operation.data());
    fprintf(stderr,"what: %s\n",x->what.data());
    return 3;
  }
  else
  if (flx_assert_failure_t *x = dynamic_cast<flx_assert_failure_t*>(e))
  {
    fprintf(stderr,"Assertion Failure\n");
    print_loc(stderr,x->flx_loc,x->cxx_srcfile, x->cxx_srcline);
    return 3;
  }
  else
  if (flx_assert2_failure_t *x = dynamic_cast<flx_assert2_failure_t*>(e))
  {
    fprintf(stderr,"Assertion2 Failure\n");
    print_loc(stderr,x->flx_loc,x->cxx_srcfile, x->cxx_srcline);
    print_loc(stderr,x->flx_loc2,x->cxx_srcfile, x->cxx_srcline);
    return 3;
  }
  else
  if (flx_match_failure_t *x = dynamic_cast<flx_match_failure_t*>(e))
  {
    fprintf(stderr,"Match Failure\n");
    print_loc(stderr,x->flx_loc,x->cxx_srcfile, x->cxx_srcline);
    return 3;
  }
  else
  if (flx_range_failure_t *x = dynamic_cast<flx_range_failure_t*>(e))
  {
    fprintf(stderr,"Range Check Failure %ld <= %ld < %ld\n",x.min, x.v,x.max);
    print_loc(stderr,x->flx_loc,x->cxx_srcfile, x->cxx_srcline);
    return 3;
  }
  else
  if (dynamic_cast<flx_out_of_memory_t*>(e))
  {
    fprintf(stderr,"Felix Out of Malloc or Specified Max allocation Exceeded");
    return 3;
  }
  else
  {
    fprintf(stderr,"Unknown EXCEPTION!\n");
    return 5;
  }
}
