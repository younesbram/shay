# Security

Shay is alpha software with a small privileged surface:

- one root-owned native Swift executable;
- exact `on` and `off` sudo rules pinned to its SHA-256;
- absolute system-command paths and a fixed root environment;
- atomic root-owned state and a no-follow file lock;
- verified `pmset` postconditions and fail-closed sensor handling.

Root execution ignores all test overrides. A failed or ambiguous transition
keeps the guard armed until normal sleep is verified.

Known limits:

- `pmset disablesleep` is an undocumented macOS interface;
- the 15-second launchd interval is not a real-time deadline;
- software cannot protect a kernel-stalled or physically heat-trapped Mac;
- root compromise and malicious build toolchains are out of scope.

Report privilege-escalation and fail-open bugs privately rather than in a public
issue.
