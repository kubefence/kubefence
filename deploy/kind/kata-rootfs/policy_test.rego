package agent_policy

import future.keywords.if
import future.keywords.in

# ── shared mount fixtures ─────────────────────────────────────────────────────
# These replicate the OCI mount entries the kata-agent sees at runtime,
# derived from genpolicy analysis of the manifests in fixtures/ and
# attack-manifests/.

# Standard kernel pseudo-filesystem mounts present in every container.
proc_mount := {"destination": "/proc", "type_": "proc", "source": "proc",
    "options": ["nosuid", "noexec", "nodev"]}

# The single /nono bind-mount appended by BuildAdjustment for every
# sandboxed container (readonly, from the host nono binary directory).
nri_nono_mount := {"destination": "/nono", "type_": "bind",
    "source": "/opt/nono-nri",
    "options": ["bind", "ro", "rprivate"]}

# ── CopyFileRequest ───────────────────────────────────────────────────────────

# Exact path "/nono" must be blocked (copy to the directory itself).
test_copy_blocked_exact_nono_dir if {
    not CopyFileRequest with input as {"path": "/nono"}
}

# Binary path must be blocked.
test_copy_blocked_nono_binary if {
    not CopyFileRequest with input as {"path": "/nono/nono"}
}

# Wrapper script paths under /nono/ must be blocked.
test_copy_blocked_nono_wrapper_sh if {
    not CopyFileRequest with input as {"path": "/nono/sh"}
}

test_copy_blocked_nono_wrapper_python if {
    not CopyFileRequest with input as {"path": "/nono/python3"}
}

# Paths at completely different locations must be allowed.
test_copy_allowed_data if {
    CopyFileRequest with input as {"path": "/data/file.txt"}
}

test_copy_allowed_tmp if {
    CopyFileRequest with input as {"path": "/tmp/upload"}
}

test_copy_allowed_etc if {
    CopyFileRequest with input as {"path": "/etc/app/config.yaml"}
}

# A path that shares the string prefix "/nono" but is a sibling directory
# (not under /nono/) must NOT be blocked — e.g. /nono-data.
test_copy_allowed_sibling_prefix if {
    CopyFileRequest with input as {"path": "/nono-data/file"}
}

# ── CreateContainerRequest — allowed cases ────────────────────────────────────

# fixtures/pod-nri-only.yaml
# Standard sandboxed container: only the NRI-injected /nono mount present.
# nono_prefix count == 1 → allowed.
test_create_allowed_nri_only if {
    CreateContainerRequest with input as {"OCI": {"Mounts": [
        proc_mount,
        nri_nono_mount,
    ]}}
}

# fixtures/pod-data-volume.yaml
# Sandboxed container with a user /data volume.
# /data does not match the /nono prefix; count stays 1 → allowed.
test_create_allowed_data_volume if {
    CreateContainerRequest with input as {"OCI": {"Mounts": [
        proc_mount,
        nri_nono_mount,
        {"destination": "/data", "type_": "bind",
            "source": "/run/kata-containers/shared/containers/SANDBOX/data",
            "options": ["rbind", "rprivate", "rw"]},
    ]}}
}

# fixtures/pod-multi-user-volumes.yaml
# Sandboxed container with user volumes at /data and /config.
# Neither touches the /nono prefix; count stays 1 → allowed.
test_create_allowed_multi_user_volumes if {
    CreateContainerRequest with input as {"OCI": {"Mounts": [
        proc_mount,
        nri_nono_mount,
        {"destination": "/data",   "type_": "bind",
            "source": "/run/kata-containers/shared/containers/SANDBOX/data",
            "options": ["rbind", "rprivate", "rw"]},
        {"destination": "/config", "type_": "bind",
            "source": "/run/kata-containers/shared/containers/SANDBOX/configmap",
            "options": ["rbind", "rprivate", "ro"]},
    ]}}
}

# fixtures/pod-pause-container.yaml
# Pause (sandbox) container: NRI does not inject /nono into the pause container.
# nono_prefix count == 0 → allowed.
test_create_allowed_pause_container if {
    CreateContainerRequest with input as {"OCI": {"Mounts": [
        proc_mount,
    ]}}
}

# Non-sandboxed container (runtime class not in nono-nri's watch list).
# NRI skips injection; zero /nono mounts → allowed.
test_create_allowed_non_sandboxed if {
    CreateContainerRequest with input as {"OCI": {"Mounts": [
        proc_mount,
        {"destination": "/data", "type_": "bind",
            "source": "/run/kata-containers/shared/containers/SANDBOX/data",
            "options": ["rbind", "rprivate", "rw"]},
    ]}}
}

# A path that shares the string prefix "/nono" but is a sibling directory
# must not affect the count — /nono-data is not /nono or /nono/...
test_create_allowed_sibling_nono_prefix_dir if {
    CreateContainerRequest with input as {"OCI": {"Mounts": [
        proc_mount,
        nri_nono_mount,
        {"destination": "/nono-data", "type_": "bind",
            "source": "/run/kata-containers/shared/containers/SANDBOX/nono-data",
            "options": ["rbind", "rprivate", "rw"]},
    ]}}
}

# ── CreateContainerRequest — denied cases ─────────────────────────────────────
# User-specified volume mounts carry "rbind" in their OCI options; the
# NRI-injected /nono mount uses "bind" (non-recursive).  The policy blocks any
# /nono-prefix mount that has "rbind", covering both the NRI-present and
# NRI-absent scenarios.

# attack-manifests/attack-hostpath-nono-binary.yaml
# hostPath file at /nono/nono (rbind) → denied even with NRI /nono present.
test_create_denied_hostpath_nono_binary if {
    not CreateContainerRequest with input as {"OCI": {"Mounts": [
        proc_mount,
        {"destination": "/nono/nono", "type_": "bind",
            "source": "/tmp/evil-binary",
            "options": ["rbind", "rprivate", "rw"]},
        nri_nono_mount,
    ]}}
}

# NRI-absent scenario: user supplies a single /nono mount (rbind) with no NRI
# mount present.  The previous count > 1 rule would have allowed this (count
# == 1); the rbind discriminator correctly denies it.
test_create_denied_user_nono_when_nri_absent if {
    not CreateContainerRequest with input as {"OCI": {"Mounts": [
        proc_mount,
        {"destination": "/nono", "type_": "bind",
            "source": "/tmp/evil-nono",
            "options": ["rbind", "rprivate", "ro"]},
    ]}}
}

# ── ExecProcessRequest ────────────────────────────────────────────────────────

# Valid nono-wrap exec with the default profile.
test_exec_allowed_default_profile if {
    ExecProcessRequest with input as {"process": {"Args":
        ["/nono/nono", "wrap", "--profile", "default", "--", "bash"]}}
}

# Valid nono-wrap exec with a custom profile name (alphanumeric + hyphen).
test_exec_allowed_custom_profile if {
    ExecProcessRequest with input as {"process": {"Args":
        ["/nono/nono", "wrap", "--profile", "strict-v2", "--", "python3", "app.py"]}}
}

# Valid nono-wrap exec with multiple trailing arguments.
test_exec_allowed_multi_args if {
    ExecProcessRequest with input as {"process": {"Args":
        ["/nono/nono", "wrap", "--profile", "default", "--", "sh", "-c", "echo hi"]}}
}

# Direct shell exec without nono wrap must be denied.
test_exec_denied_direct_bash if {
    not ExecProcessRequest with input as {"process": {"Args": ["bash"]}}
}

# Invoking nono binary without the wrap subcommand must be denied.
test_exec_denied_nono_without_wrap if {
    not ExecProcessRequest with input as {"process": {"Args": ["/nono/nono", "bash"]}}
}

# Profile name starting with a digit followed by a hyphen is valid per regex.
test_exec_allowed_profile_leading_digit if {
    ExecProcessRequest with input as {"process": {"Args":
        ["/nono/nono", "wrap", "--profile", "1prod", "--", "cat", "/etc/hosts"]}}
}

# Profile name starting with a hyphen (flag injection attempt) must be denied.
test_exec_denied_profile_leading_hyphen if {
    not ExecProcessRequest with input as {"process": {"Args":
        ["/nono/nono", "wrap", "--profile", "-xbad", "--", "bash"]}}
}

# Profile name with 65 characters exceeds the 64-char limit — must be denied.
test_exec_denied_profile_too_long if {
    not ExecProcessRequest with input as {"process": {"Args":
        ["/nono/nono", "wrap", "--profile",
         "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaX",
         "--", "bash"]}}
}
