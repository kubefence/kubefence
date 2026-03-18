# Roadmap: nono-nri

## Overview

Build an NRI plugin that sandboxes Kubernetes container commands using nono/Landlock without modifying container images. Phase 1 establishes a working plugin process that connects to CRI-O, correctly filters containers, and logs decisions — returning no-op adjustments until the injection logic is proven safe. Phase 2 adds the core value: SetArgs() command wrapping and nono binary bind-mount injection. Phase 3 deploys the complete plugin to a real Kubernetes cluster via DaemonSet and validates end-to-end sandboxing.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: NRI Foundation** - Plugin skeleton that connects to CRI-O, filters containers by RuntimeClass, resolves nono profiles, and logs decisions — no injection yet (completed 2026-03-18)
- [ ] **Phase 2: Command Wrapping** - SetArgs() injection prepends `nono wrap` to container process.args, bind-mounts the nono binary, and manages per-container host-side state
- [ ] **Phase 3: Deployment** - DaemonSet with init container, CRI-O nri_plugin_dir compatibility, and end-to-end validation on a real test cluster

## Phase Details

### Phase 1: NRI Foundation
**Goal**: A running NRI plugin that correctly identifies which containers to sandbox and logs every decision, without touching process.args
**Depends on**: Nothing (first phase)
**Requirements**: CORE-01, CORE-02, CORE-03, CORE-04, SAFE-01
**Success Criteria** (what must be TRUE):
  1. Plugin process starts, connects to CRI-O NRI socket, and remains running as a persistent daemon without crashing on startup
  2. Plugin logs a structured JSON skip record for every pause/infra container and every container whose pod is not in the configured RuntimeClass list — no adjustment returned
  3. Plugin reads the `nono.sh/profile` annotation from the pod spec and falls back to the configured default profile when the annotation is absent — observable in the JSON log output
  4. Plugin refuses to start on kernels older than 5.13 with a non-zero exit and a clear error message identifying the kernel version
  5. Plugin emits a structured JSON injection-pending record (with container ID, namespace, pod, profile, runtime handler) for every container that passes the filter — confirming selection logic before Phase 2 adds actual injection
**Plans:** 3/3 plans complete

Plans:
- [x] 01-01-PLAN.md — Go module setup + core internal packages (config, kernel, filter, profile, log) with unit tests
- [x] 01-02-PLAN.md — NRI plugin struct + main entrypoint + plugin unit tests + build verification
- [x] 01-03-PLAN.md — Integration tests exercising full plugin flow + final verification gate

### Phase 2: Command Wrapping
**Goal**: Opted-in containers have their process.args prepended with `nono wrap --profile <name> --` and the nono binary bind-mounted into the container before it starts
**Depends on**: Phase 1
**Requirements**: WRAP-01, WRAP-02, WRAP-03
**Success Criteria** (what must be TRUE):
  1. A container started in a sandboxed RuntimeClass runs with `nono wrap` as the effective entrypoint — observable by exec-ing into the container and inspecting `/proc/1/cmdline`
  2. The nono binary is accessible inside the container at the expected container-internal path — observable by running `ls` at that path from inside the container
  3. Per-container state directory exists under `/var/run/nono-nri/{podID}/{containerID}/` while the container is running and is removed after the container is deleted — observable on the host node filesystem
  4. Containers not in the designated RuntimeClass start normally with unmodified process.args — confirming the opt-in gate holds under Phase 2 injection code
**Plans:** 3 plans

Plans:
- [ ] 02-01-PLAN.md — BuildAdjustment (SetArgs + AddMount) and state management (WriteMetadata/RemoveMetadata) with full unit tests
- [ ] 02-02-PLAN.md — Wire injection into plugin.go + NonoBinPath startup validation + update plugin and integration tests
- [ ] 02-03-PLAN.md — End-to-end injection lifecycle integration test + full suite gate with race detector

### Phase 3: Deployment
**Goal**: The nono-nri plugin deploys to a test Kubernetes cluster via DaemonSet and sandboxes containers end-to-end using both runc and Kata runtimes
**Depends on**: Phase 2
**Requirements**: DEPL-01, DEPL-02, DEPL-03
**Success Criteria** (what must be TRUE):
  1. `kubectl apply -f daemonset.yaml` deploys the plugin to all nodes; DaemonSet pods reach Running state with no restarts
  2. A test pod using the sandboxed RuntimeClass starts successfully and its entrypoint runs under Landlock — observable by the nono process appearing in container process tree and sandboxing taking effect on filesystem access
  3. The nono binary is present on the host at the expected hostPath after DaemonSet init container runs — observable via `ls` on the node or via `kubectl exec` on the DaemonSet pod
  4. Plugin binary placed in CRI-O's nri_plugin_dir with the two-digit index prefix is auto-started by CRI-O without requiring DaemonSet registration — observable in CRI-O logs showing plugin connected
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. NRI Foundation | 3/3 | Complete   | 2026-03-18 |
| 2. Command Wrapping | 0/3 | Planning complete | - |
| 3. Deployment | 0/? | Not started | - |
