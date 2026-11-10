#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;
typedef int (*execve_fn)(const char *, char *const[], char *const[]);

static int resolve_guest_path(const char *filename, const char *rootfs, char *out, size_t out_sz) {
    if (!filename || !rootfs || !rootfs[0]) return 0;
    size_t rlen = strlen(rootfs);
    if (strncmp(filename, rootfs, rlen) == 0 && (filename[rlen] == '/' || filename[rlen] == '\0')) {
        snprintf(out, out_sz, "%s", filename);
        return 1;
    }
    if (filename[0] == '/') {
        snprintf(out, out_sz, "%s%s", rootfs, filename);
        struct stat st;
        if (stat(out, &st) == 0) {
            return 1;
        }
    }
    return 0;
}

int execve(const char *filename, char *const argv[], char *const envp[]) {
    execve_fn real_execve = (execve_fn)dlsym(RTLD_NEXT, "execve");
    const char *qemu_bin = getenv("SAMP_QEMU_BIN");
    const char *rootfs = getenv("QEMU_LD_PREFIX");

    if (!qemu_bin || !qemu_bin[0] || !rootfs || !rootfs[0] || !filename) {
        return real_execve(filename, argv, envp);
    }

    if (strcmp(filename, qemu_bin) == 0) {
        return real_execve(filename, argv, envp);
    }

    char resolved[PATH_MAX];
    const char *target = filename;
    if (resolve_guest_path(filename, rootfs, resolved, sizeof(resolved))) {
        target = resolved;
    }

    char interp[PATH_MAX] = {0};
    char interp_arg[PATH_MAX] = {0};
    int fd = open(target, O_RDONLY);
    if (fd >= 0) {
        char buf[256] = {0};
        ssize_t n = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (n >= 2 && buf[0] == '#' && buf[1] == '!') {
            char *nl = strchr(buf, '\n');
            if (nl) *nl = '\0';
            char *p = buf + 2;
            while (*p == ' ' || *p == '\t') p++;
            char *sp = strpbrk(p, " \t\r");
            if (sp) {
                *sp++ = '\0';
                while (*sp == ' ' || *sp == '\t' || *sp == '\r') sp++;
                snprintf(interp_arg, sizeof(interp_arg), "%s", sp);
            }
            char res_interp[PATH_MAX];
            if (resolve_guest_path(p, rootfs, res_interp, sizeof(res_interp))) {
                snprintf(interp, sizeof(interp), "%s", res_interp);
            } else {
                snprintf(interp, sizeof(interp), "%s", p);
            }
        }
    }

    int argc = 0;
    if (argv) {
        while (argv[argc]) argc++;
    }

    const char **new_argv = (const char **)calloc((size_t)argc + 8, sizeof(char *));
    if (!new_argv) {
        errno = ENOMEM;
        return -1;
    }

    int k = 0;
    new_argv[k++] = qemu_bin;
    new_argv[k++] = "-L";
    new_argv[k++] = rootfs;
    if (interp[0]) {
        new_argv[k++] = interp;
        if (interp_arg[0]) {
            new_argv[k++] = interp_arg;
        }
    }
    new_argv[k++] = target;
    for (int i = 1; i < argc; i++) {
        new_argv[k++] = argv[i];
    }
    new_argv[k] = NULL;

    int ret = real_execve(qemu_bin, (char *const *)new_argv, envp);
    int saved_errno = errno;
    free(new_argv);
    errno = saved_errno;
    return ret;
}

int execv(const char *path, char *const argv[]) {
    return execve(path, argv, environ);
}

int execvpe(const char *file, char *const argv[], char *const envp[]) {
    if (!file || !file[0]) {
        errno = ENOENT;
        return -1;
    }
    if (strchr(file, '/')) {
        return execve(file, argv, envp);
    }
    const char *rootfs = getenv("QEMU_LD_PREFIX");
    const char *path_env = getenv("PATH");
    if (!path_env) path_env = "/usr/bin:/bin:/usr/sbin:/sbin";
    char *paths = strdup(path_env);
    if (!paths) return -1;

    char candidate[PATH_MAX];
    char *saveptr = NULL;
    for (char *dir = strtok_r(paths, ":", &saveptr); dir; dir = strtok_r(NULL, ":", &saveptr)) {
        if (rootfs && rootfs[0] && strncmp(dir, rootfs, strlen(rootfs)) != 0) {
            snprintf(candidate, sizeof(candidate), "%s%s/%s", rootfs, dir, file);
            if (access(candidate, X_OK) == 0) {
                free(paths);
                return execve(candidate, argv, envp);
            }
        }
        snprintf(candidate, sizeof(candidate), "%s/%s", dir, file);
        if (access(candidate, X_OK) == 0) {
            free(paths);
            return execve(candidate, argv, envp);
        }
    }
    free(paths);
    errno = ENOENT;
    return -1;
}

int execvp(const char *file, char *const argv[]) {
    return execvpe(file, argv, environ);
}
