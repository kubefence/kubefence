package agent_policy

import future.keywords.in
import future.keywords.if

# Allow-list: all standard kata-agent requests are permitted by default,
# except those explicitly hardened below.
default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CreateSandboxRequest := true
default DestroySandboxRequest := true
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
default ReadStreamRequest := true
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := true
default StatsContainerRequest := true
default StopTracingRequest := true
default TtyWinResizeRequest := true
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default WriteStreamRequest := true
default SetPolicyRequest := true

# ── ExecProcessRequest ────────────────────────────────────────────────────────
# kubectl exec is allowed only when routed through the nono sandbox wrapper.
# The command must be: /nono/nono wrap --profile <name> -- <cmd ...>
# Profile names are restricted to safe identifiers (alphanumeric, hyphen,
# underscore, leading alphanumeric) to prevent CLI flag injection.
default ExecProcessRequest := false

ExecProcessRequest if {
    i_command := concat(" ", input.process.Args)
    regex.match(`^/nono/nono wrap --profile [a-zA-Z0-9][a-zA-Z0-9_-]{0,63} -- .+$`, i_command)
}

# ── CopyFileRequest ───────────────────────────────────────────────────────────
# Block direct file copies into the /nono directory.
#
# CopyFileRequest is the kata-agent gRPC method that transfers files directly
# into the guest VM filesystem (used by kata-ctl and similar tools). Allowing
# copies to /nono would let an attacker silently replace the nono sandbox
# binary or its wrapper scripts, bypassing Landlock enforcement for every
# subsequent container exec.
#
# Attack: kata-ctl cp ./evil /nono/nono  →  CopyFileRequest {path: "/nono/nono"}
# Attack: copy to /nono/ directory        →  CopyFileRequest {path: "/nono/"}
default CopyFileRequest := false

CopyFileRequest if {
    not copies_to_nono_path
}

copies_to_nono_path if {
    input.path == "/nono"
}

copies_to_nono_path if {
    startswith(input.path, "/nono/")
}

# ── CreateContainerRequest ────────────────────────────────────────────────────
# Block containers whose OCI spec carries more than one /nono-prefix mount,
# which indicates a user-controlled volume at /nono/nono alongside the
# legitimate NRI-injected /nono dir mount.
#
# Two-layer defence model (verified on a live kata-nono-qemu cluster):
#
# Layer 1 — NRI mount replacement (handled outside this rule):
#   When a user spec declares a volume at /nono (same destination as the NRI
#   bind-mount), containerd merges OCI mounts by destination and the NRI
#   read-only bind-mount wins.  The kata-agent therefore sees only ONE /nono
#   entry; count == 1 and this rule allows the container.  Inside the VM the
#   trusted nono binary is present; the attack payload is never visible.
#   Attacks neutralised by Layer 1: hostPath dir, emptyDir, ConfigMap/Secret
#   dir all mounted at /nono.
#
# Layer 2 — this policy rule:
#   A hostPath file mount at /nono/nono has a DIFFERENT OCI destination from
#   the NRI /nono dir mount, so both entries survive the merge.  The count
#   reaches 2, and this rule denies CreateContainerRequest with
#   "CreateContainerRequest is blocked by policy".
#   Attack caught by Layer 2: hostPath file at /nono/nono.
#
# Containers with zero /nono mounts (pause, non-sandboxed) pass as well
# since 0 <= 1.
#
# Note: kubectl cp attacks via exec+tar are blocked by ExecProcessRequest.
#       subPath mounts at /nono/nono are unsupported by Kata (genpolicy panics).
default CreateContainerRequest := false

CreateContainerRequest if {
    not container_has_extra_nono_mounts
}

container_has_extra_nono_mounts if {
    nono_mounts := [m | some m in input.OCI.Mounts; nono_prefix_destination(m.destination)]
    count(nono_mounts) > 1
}

nono_prefix_destination(dest) if {
    dest == "/nono"
}

nono_prefix_destination(dest) if {
    startswith(dest, "/nono/")
}
