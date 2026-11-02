// libgit2 for Swift. The include path is passed by scripts/build-mac.sh.
#include <git2.h>

// git_libgit2_opts is variadic, which Swift cannot call; these wrap the settings the app needs.

/** Gives up on unreachable or stalled servers instead of waiting forever. */
static inline int gn_set_timeouts(int milliseconds) {
    int error = git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT, milliseconds);
    return error ? error : git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT, milliseconds);
}

/**
 * Trusts the certificates that come with macOS. Otherwise the bundled OpenSSL looks in the Homebrew
 * folder of the Mac that built the app, which other Macs don't have, and every HTTPS connection fails.
 */
static inline int gn_use_system_certificates(void) {
    return git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, "/etc/ssl/cert.pem", NULL);
}

/** Ignores the user's own Git configuration (~/.gitconfig, /etc/gitconfig), like the Android app. */
static inline int gn_isolate_config(void) {
    int levels[] = { GIT_CONFIG_LEVEL_SYSTEM, GIT_CONFIG_LEVEL_XDG, GIT_CONFIG_LEVEL_GLOBAL, GIT_CONFIG_LEVEL_PROGRAMDATA };
    for (int i = 0; i < 4; i++) {
        int error = git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, levels[i], "");
        if (error) return error;
    }
    return 0;
}
