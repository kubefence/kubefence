package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/containerd/nri/pkg/stub"

	applog "github.com/k8s-nono/nono-nri/internal/log"
	"github.com/k8s-nono/nono-nri/internal/nri"
)

func run() error {
	var configPath string
	var jsonMode bool
	var logLevel string

	flag.StringVar(&configPath, "config", "/etc/nri/conf.d/10-nono-nri.toml", "path to TOML config file")
	flag.BoolVar(&jsonMode, "json", true, "output logs as JSON")
	flag.StringVar(&logLevel, "log-level", "info", "log level: debug, info, warn, error")
	flag.Parse()

	var level slog.Level
	if err := level.UnmarshalText([]byte(logLevel)); err != nil {
		return fmt.Errorf("invalid log level %q: %w", logLevel, err)
	}

	// Kernel check FIRST (SAFE-01): verify Landlock LSM support before any
	// other initialization. This prevents startup on unsupported kernels.
	if err := nri.CheckKernel(); err != nil {
		return fmt.Errorf("startup check failed: %w", err)
	}

	cfg, err := nri.LoadConfig(configPath)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}

	if cfg.NonoBinPath != "" {
		info, err := os.Stat(cfg.NonoBinPath)
		if err != nil {
			return fmt.Errorf("nono binary not found at %s: %w", cfg.NonoBinPath, err)
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("nono binary at %s is not a regular file", cfg.NonoBinPath)
		}
		if info.Mode()&0o111 == 0 {
			return fmt.Errorf("nono binary at %s is not executable", cfg.NonoBinPath)
		}
	}

	logger := applog.New(jsonMode, level)

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

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	logger.Info("nono-nri starting",
		"config", configPath,
		"runtime_classes", cfg.RuntimeClasses,
		"default_profile", cfg.DefaultProfile,
	)

	if err := s.Run(ctx); err != nil {
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
