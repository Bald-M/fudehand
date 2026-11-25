#include <errno.h>
#include <stdio.h>

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fputs("Usage: publish-native-app <staged-app> <destination>\n", stderr);
        return 2;
    }

    // The first build only needs a rename. Replacing a non-empty bundle needs an atomic exchange.
    if (renamex_np(argv[1], argv[2], RENAME_EXCL) == 0) return 0;
    if (errno == EEXIST && renamex_np(argv[1], argv[2], RENAME_SWAP) == 0) return 0;

    perror("Could not publish Fudehand.app");
    return 1;
}
