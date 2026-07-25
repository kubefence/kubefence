package nri

import (
	"bytes"
	"errors"
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
		// DisallowUnknownFields reports only "fields in the document are missing
		// in the target struct" — no indication of which key. StrictMissingError
		// carries a rendered excerpt naming the offending key and line, which is
		// what makes a removed key (e.g. vm_rootfs_classes) diagnosable.
		var strictErr *toml.StrictMissingError
		if errors.As(err, &strictErr) {
			return nil, fmt.Errorf("parsing config: unknown key(s):\n%s", strictErr.String())
		}
		return nil, fmt.Errorf("parsing config: %w", err)
	}
	if len(cfg.RuntimeClasses) == 0 {
		return nil, fmt.Errorf("config: runtime_classes must not be empty")
	}
	if !validProfileRe.MatchString(cfg.DefaultProfile) {
		return nil, fmt.Errorf("config: default_profile %q is invalid: must match ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", cfg.DefaultProfile)
	}
	// nono is always delivered by host bind-mount, for every handler — a plain
	// bind for runc, virtiofs for Kata — so nono_bin_path is unconditionally
	// required.
	if cfg.NonoBinPath == "" {
		return nil, fmt.Errorf("config: nono_bin_path must not be empty")
	}
	// A relative NonoBinPath causes filepath.Dir to return "." which silently
	// becomes the bind-mount source, mounting the plugin's cwd into containers.
	if !filepath.IsAbs(cfg.NonoBinPath) {
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
