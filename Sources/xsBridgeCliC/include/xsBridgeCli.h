#ifndef XSB_CLI_H
#define XSB_CLI_H

void xsBridgeCliInstall(void* machine);

/* Register the snapshot host table only (no machine) — call before restoring
 * a snapshot. */
void xsBridgeCliRegister(void);

#endif
