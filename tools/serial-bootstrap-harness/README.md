# Offline serial bootstrap reproduction

Run from this directory with Xcode Command Line Tools and an existing GNU Readline 8.x installation:

```bash
READLINE_PREFIX=/opt/homebrew/opt/readline bash run-harness.sh /private/tmp/EchoGuideSerialResults
```

Nothing is installed. The runner compiles the current repository serial transport, login and bootstrap code in a disposable temporary directory. A generated old producer removes only the reviewed initial output newline. Two bridged local PTYs exercise Bash, zsh and modern Readline at 80/132 columns, with two consecutive exchanges each. Identity, architecture, network and public host-key values are synthetic fixtures. Normal results contain fixture summaries without transcripts. Optional `ECHOGUIDE_HARNESS_CAPTURE=1` captures synthetic fixture transcripts locally. No UTM, SSH, real credentials, sessions or Echo are accessed.

The old producer must fail both Readline cases with BEGIN 0 / END 1. The current producer must pass all six cases (12 exchanges). This validates framing; it does not establish live guest bootstrap, SSH key installation or workflow readiness. The normal XCTest actual-command regression needs no Readline dependency.
