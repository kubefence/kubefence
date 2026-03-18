package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/containerd/nri/pkg/stub"

	applog "github.com/k8s-nono/nono-nri/internal/log"
	"github.com/k8s-nono/nono-nri/internal/nri"
)

func run() error {
	var configPath string
	var jsonMode bool

	flag.StringVar(&configPath, "config", "/etc/nri/conf.d/10-nono-nri.toml", "path to TOML config file")
	flag.BoolVar(&jsonMode, "json", true, "output logs as JSON")
	flag.Parse()

	// Kernel check FIRST (SAFE-01): verify Landlock LSM support before any
	// other initialization. This prevents startup on unsupported kernels.
	if err := nri.CheckKernel(); err != nil {
		return fmt.Errorf("startup check failed: %w", err)
	}

	cfg, err := nri.LoadConfig(configPath)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}

	if _, err := os.Stat(cfg.NonoBinPath); err != nil {
		return fmt.Errorf("nono binary not found at %s: %w", cfg.NonoBinPath, err)
	}

	logger := applog.New(jsonMode)

	p := nri.NewPlugin(cfg, logger)

	opts := []stub.Option{
		stub.WithPluginName("nono-nri"),
		stub.WithPluginIdx("10"),
	}
	if cfg.SocketPath != "" {
		opts = append(opts, stub.WithSocketPath(cfg.SocketPath))
	}

	s, err := stub.New(p, opts...)
	if err != nil {
		return fmt.Errorf("creating NRI stub: %w", err)
	}

	logger.Info("nono-nri starting",
		"config", configPath,
		"runtime_classes", cfg.RuntimeClasses,
		"default_profile", cfg.DefaultProfile,
	)

	if err := s.Run(context.Background()); err != nil {
		return fmt.Errorf("plugin exited: %w", err)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "nono-nri: %v\n", err)
		os.Exit(1)
	}
}
