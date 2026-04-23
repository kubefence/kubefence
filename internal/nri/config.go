package nri

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"

	"github.com/pelletier/go-toml/v2"
)

// Config holds the nono-nri plugin configuration loaded from a TOML file.
type Config struct {
	RuntimeClasses []string `toml:"runtime_classes"`
	DefaultProfile string   `toml:"default_profile"`
	NonoBinPath    string   `toml:"nono_bin_path"`
	SocketPath     string   `toml:"socket_path"`
	// VMRootfsClasses lists RuntimeClass handler names whose pods run inside a
	// Kata VM with nono pre-installed in the guest rootfs at /nono/nono.
	// For these handlers the per-container host bind-mount is skipped;
	// NONO_PROFILE is injected as an env var instead so wrapper scripts
	// invoked via kubectl exec can apply the correct profile.
	// Handlers not listed here use bind-mount delivery (default behaviour).
	VMRootfsClasses []string `toml:"vm_rootfs_classes"`
	// SeccompProfile names the seccomp policy injected into every sandboxed
	// container via ContainerAdjustment.SetLinuxSeccompPolicy.
	// "restricted"      — RuntimeDefault minus io_uring, ptrace, seccomp,
	//                     and pidfd_getfd; recommended for AI workloads.
	// "runtime-default" — Docker RuntimeDefault allowlist verbatim.
	// ""                — disabled; no seccomp policy is injected.
	// For Kata handlers, disable_guest_seccomp must be false in the QEMU
	// config for the kata-agent to apply this policy inside the VM.
	SeccompProfile string `toml:"seccomp_profile"`
}

// IsVMRootfsClass reports whether the given RuntimeClass handler uses the
// embedded-nono VM rootfs delivery rather than the host bind-mount.
func (c *Config) IsVMRootfsClass(handler string) bool {
	for _, h := range c.VMRootfsClasses {
		if h == handler {
			return true
		}
	}
	return false
}

// LoadConfig reads and parses a TOML config file at the given path.
// Returns an error if the file cannot be read, fails to parse, or required fields are invalid.
// Unknown TOML keys are silently ignored (go-toml/v2 default behaviour — intentional).
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config: %w", err)
	}
	var cfg Config
	dec := toml.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}
	if len(cfg.RuntimeClasses) == 0 {
		return nil, fmt.Errorf("config: runtime_classes must not be empty")
	}
	if !validProfileRe.MatchString(cfg.DefaultProfile) {
		return nil, fmt.Errorf("config: default_profile %q is invalid: must match ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", cfg.DefaultProfile)
	}
	// nono_bin_path is required for any handler that uses bind-mount delivery.
	if cfg.NonoBinPath == "" {
		for _, rc := range cfg.RuntimeClasses {
			if !cfg.IsVMRootfsClass(rc) {
				return nil, fmt.Errorf("config: nono_bin_path must not be empty when bind-mount delivery is used (handler %q is not in vm_rootfs_classes)", rc)
			}
		}
	}
	// A relative NonoBinPath causes filepath.Dir to return "." which silently
	// becomes the bind-mount source, mounting the plugin's cwd into containers.
	if cfg.NonoBinPath != "" && !filepath.IsAbs(cfg.NonoBinPath) {
		return nil, fmt.Errorf("config: nono_bin_path %q must be an absolute path", cfg.NonoBinPath)
	}
	switch cfg.SeccompProfile {
	case "", SeccompProfileRuntimeDefault, SeccompProfileRestricted:
		// valid
	default:
		return nil, fmt.Errorf("config: seccomp_profile %q is invalid: must be %q, %q, or empty",
			cfg.SeccompProfile, SeccompProfileRuntimeDefault, SeccompProfileRestricted)
	}
	return &cfg, nil
}
