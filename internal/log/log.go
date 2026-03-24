package log

import (
	"log/slog"
	"os"
)

// New creates a new slog.Logger at the given level.
// When jsonMode is true, it returns a JSON logger writing to stdout (production mode).
// When jsonMode is false, it returns a human-readable text logger writing to stderr (development mode).
func New(jsonMode bool, level slog.Level) *slog.Logger {
	opts := &slog.HandlerOptions{Level: level}
	if jsonMode {
		return slog.New(slog.NewJSONHandler(os.Stdout, opts))
	}
	return slog.New(slog.NewTextHandler(os.Stderr, opts))
}
