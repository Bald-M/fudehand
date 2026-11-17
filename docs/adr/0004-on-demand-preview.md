# Start Example Servers on Demand

> Superseded by [ADR 0006](0006-native-design-document.md): the web-project pipeline has been removed, and this document is kept only as a historical record.

2026-11-17. At startup the App used to launch the dev servers of all enabled web projects, and became interactive only once all of them were ready; the more web projects, the slower the startup and the more background processes, while users usually look at only one web project at a time (#23).

Switch to on-demand startup: after validating the catalog, `native-preview.mjs` only prints `UI_ATLAS_LISTENING` and starts no servers. When the App selects a web project it writes `start <id>` to stdin; the launcher starts that web project with `createServicePool` from `launcher.mjs`, prints `UI_ATLAS_READY <id>` to stdout once HTTP is ready, and on failure prints `UI_ATLAS_FAILED <id> <JSON message>`. stdout carries only the protocol; logs go to stderr, and the App attaches the most recent logs to the failure description.

Constraints kept: check the port before starting, never kill an external process holding the port, and never switch ports; when a single web project fails to start or exits unexpectedly, clean up only that web project's process group while the others keep running, and the user can retry it alone; on stdin EOF or a termination signal, close all process groups. Started web projects stay up for as long as the App runs, so switching back to one needs no further wait.

## Rejected Alternatives

- **One launcher process per web project**: the App would need to manage multiple pipes and the exits of multiple child processes, and the constraint that stdin EOF cleans up all process groups would have to be guaranteed separately for each process. A single launcher with a line protocol is simpler.
- **Automatically stop web projects that have not been viewed for a long time**: listed as optional in the Issue. There are few web projects for now, and auto-stopping would make switching back wait for startup again; `createServicePool` already provides `stop(id)`, so an idle policy can be wired into the App when needed.

## Consequences

- The App becomes interactive as soon as the first web project is ready, no longer held back by the slowest or a failed web project; web projects not being viewed do not occupy dev-server processes.
- Startup time (the two Vite examples in the repository, from starting `native-preview.mjs` until interactive, measured 3 times each, the first being a cold start): before the change, waiting for both web projects to print `UI_ATLAS_READY` took 1687 / 465 / 462ms; after the change, starting only the current web project until `UI_ATLAS_READY still` took 568 / 463 / 462ms. The two examples were already started in parallel, so warm startup times are similar; the gains are going from 2 dev-server processes to 1 and failures no longer holding back other web projects. The difference grows as web projects are added or when one is slow.
- `canvas_restart_preview` still restarts the whole launcher, after which only the current web project is started again.
