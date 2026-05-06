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
# Block containers that carry a user-controlled volume at /nono or /nono/*.
#
# Key discriminator — rbind vs bind:
#   User-specified Kubernetes volume mounts are converted to OCI mounts with
#   "rbind" (recursive bind) by containerd.  The NRI-injected /nono mount uses
#   "bind" (non-recursive), set explicitly by BuildAdjustment:
#     Options: []string{"bind", "ro", "rprivate"}
#   Checking for "rbind" therefore identifies user-supplied mounts regardless
#   of whether the NRI plugin is running, closing the gap where a single user
#   /nono mount (count == 1) would have passed the previous count > 1 rule.
#
# NRI-absent safety: if the NRI plugin is misconfigured or absent, no /nono
#   bind-mount is injected at all (count == 0).  Legitimate containers are
#   still allowed.  Any attacker-supplied /nono mount has rbind and is denied.
#   Inside the kata VM, /nono/nono is provided by the rootfs image, so
#   ExecProcessRequest gating remains effective against a trusted binary.
#
# Attacks blocked: hostPath (dir or file), emptyDir, ConfigMap, Secret at
#   /nono or /nono/nono — all carry rbind in their OCI options.
#
# Note: kubectl cp attacks via exec+tar are blocked by ExecProcessRequest.
#       subPath mounts at /nono/nono are unsupported by Kata (genpolicy panics).
default CreateContainerRequest := false

CreateContainerRequest if {
    not container_has_user_nono_mount
}

container_has_user_nono_mount if {
    some mount in input.OCI.Mounts
    nono_prefix_destination(mount.destination)
    "rbind" in mount.options
}

nono_prefix_destination(dest) if {
    dest == "/nono"
}

nono_prefix_destination(dest) if {
    startswith(dest, "/nono/")
}
