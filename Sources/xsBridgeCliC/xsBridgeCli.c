/*
 * xsBridgeCli.c — C host functions for the CLI sandbox.
 *
 * Written against the classic xs.h API; installed on the machine by
 * xsBridgeCliInstall, called from Swift with the opaque handle (on the XS thread).
 */
#include "xsAll.h"
#include "xs.h"
#include "bridge.h"
#include "xsBridgeCli.h"
#include <sys/time.h>
#include <stdio.h>
#include <stdlib.h>


extern char* xsbGetCurrentTime(void* context);

/* print(x) — the bridge installs nothing; even print is consumer-supplied. */
static void xs_cli_print(xsMachine* the)
{
  const char* s = (xsToInteger(xsArgc) > 0) ? xsToString(xsArg(0)) : "";
  fprintf(stdout, "%s\n", s);
}

void xsGetCurrentTime(xsMachine* the)
{
  void* context = xsGetContext(the);

  char* result = xsbGetCurrentTime(context);
  if (result) {
    xsResult = xsString(result);
    free(result);
  }
}

void xsBridgeCliInstall(void* machine)
{
  xsBeginHost((xsMachine*)machine);
  {
    xsVars(1);
    xsTry {
      xsVar(0) = xsNewHostFunction(xs_cli_print, 1);
      xsSet(xsGlobal, xsID("print"), xsVar(0));

      xsVar(0) = xsNewHostFunction(xsGetCurrentTime, 0);
      xsSet(xsGlobal, xsID("getCurrentTime"), xsVar(0));
    }
    xsCatch {
    }
  }
  xsEndHost((xsMachine*)machine);
}
