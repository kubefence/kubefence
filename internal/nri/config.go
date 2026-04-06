package nri

import (
	"fmt"
	"os"

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
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}
	if len(cfg.RuntimeClasses) == 0 {
		return nil, fmt.Errorf("config: runtime_classes must not be empty")
	}
	// nono_bin_path is required for any handler that uses bind-mount delivery.
	if cfg.NonoBinPath == "" {
		for _, rc := range cfg.RuntimeClasses {
			if !cfg.IsVMRootfsClass(rc) {
				return nil, fmt.Errorf("config: nono_bin_path must not be empty when bind-mount delivery is used (handler %q is not in vm_rootfs_classes)", rc)
			}
		}
	}
	return &cfg, nil
}
