#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/wait.h>
#include <readline/readline.h>
int main(void) {
    rl_variable_bind("enable-bracketed-paste", "on");
    const char *fixture = getenv("ECHOGUIDE_REVIEW_FIXTURE");
    if (!fixture) return 2;
    char *line;
    while ((line=readline("echotest@fixture:~$ ")) != NULL) {
        pid_t child=fork();
        if (child==0) {
            execl("/bin/bash", "bash", "--noprofile", "--norc", "-c", ". \"$1\"; eval \"$2\"", "fixture-shell", fixture, line, (char *)NULL);
            _exit(127);
        }
        if (child<0) return 3;
        int status; waitpid(child, &status, 0);
        free(line);
    }
    return 0;
}
