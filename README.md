# shell

A minimal shell. An Almquist Shell (ash/dash) replacement without the posix/bash footguns.
Intended use-cases is a minimal shell for embedded systems, containers, etc.

Primary goals:
- Minimal binary size (on the order of kb not mb)
- Minimal memory usage
- Fast execution
- Quick startup
- Non-POSIX compliance

## Formatting

`bs fmt` rewrites scripts into the canonical layout. It is left out of the
default build to keep the binary small; build it with:

    zig build -Dformatter=true

Then:

    bs fmt script.bs            # format in place
    bs fmt --check *.bs         # list files that need formatting; exit 1 if any
    bs fmt < script.bs          # format stdin to stdout
