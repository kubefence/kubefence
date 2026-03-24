package nri_test

import (
	"bytes"
	"log/slog"

	nri "github.com/k8s-nono/nono-nri/internal/nri"
)

// logEntry is used to parse structured JSON log output from the plugin in all
// test files.  The Time and Level fields are populated by the JSON handler but
// are optional in assertions that do not care about them.
type logEntry struct {
	Time           string `json:"time"`
	Level          string `json:"level"`
	Msg            string `json:"msg"`
	Decision       string `json:"decision"`
	Reason         string `json:"reason"`
	ContainerID    string `json:"container_id"`
	Namespace      string `json:"namespace"`
	Pod            string `json:"pod"`
	Profile        string `json:"profile"`
	RuntimeHandler string `json:"runtime_handler"`
}

// newBufLogger creates a JSON slog.Logger that writes to the returned buffer.
func newBufLogger(buf *bytes.Buffer) *slog.Logger {
	return slog.New(slog.NewJSONHandler(buf, &slog.HandlerOptions{Level: slog.LevelDebug}))
}

// newTestPlugin creates a Plugin with the standard test config (RuntimeClass
// "nono-runc", default profile, NonoBinPath "/host/nono") writing logs to buf.
// Tests that need a non-standard config should call nri.NewPlugin directly.
func newTestPlugin(buf *bytes.Buffer) *nri.Plugin {
	return nri.NewPlugin(&nri.Config{
		RuntimeClasses: []string{"nono-runc"},
		DefaultProfile: "default",
		NonoBinPath:    "/host/nono",
	}, newBufLogger(buf))
}
