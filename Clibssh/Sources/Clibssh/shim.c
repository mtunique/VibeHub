// libssh + mbedTLS thread compatibility shim.
//
// libssh's auto_init() constructor calls ssh_init() which internally calls
// ssh_threads_init(). The default thread backend is "threads_pthread", but
// the mbedTLS crypto backend's crypto_thread_init() only accepts
// "threads_noop". This mismatch causes ssh_init() to fail with -1.
//
// Fix: register the noop thread callbacks at constructor priority 101
// (before libssh's default-priority auto_init).

#include <libssh/libssh.h>

extern struct ssh_threads_callbacks_struct *ssh_threads_get_noop(void);
extern int ssh_threads_set_callbacks(struct ssh_threads_callbacks_struct *cb);

__attribute__((constructor(101)))
static void vibehub_libssh_pre_init(void) {
    ssh_threads_set_callbacks(ssh_threads_get_noop());
}

/// Call from Swift to ensure libssh is fully initialized.
/// Returns 0 on success.
int vibehub_ssh_global_init(void) {
    return ssh_init();
}
