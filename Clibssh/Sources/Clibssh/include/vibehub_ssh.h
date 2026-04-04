#ifndef VIBEHUB_SSH_H
#define VIBEHUB_SSH_H

/// Initialize libssh global state (crypto, RNG).
/// Must be called once before any ssh_* API. Returns 0 on success.
int vibehub_ssh_global_init(void);

#endif
