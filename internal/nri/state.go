package nri

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// StateBaseDir is the root directory for per-container state files.
const StateBaseDir = "/var/run/nono-nri"

// stateBaseDir is the package-level variable used by state functions.
// It defaults to StateBaseDir and can be overridden in tests via SetStateBaseDir.
var stateBaseDir = StateBaseDir

// SetStateBaseDir overrides the base directory used for state files.
// For use in tests only. Must only be called before the plugin processes any
// container events; it is not goroutine-safe.
func SetStateBaseDir(dir string) {
	stateBaseDir = dir
}

// ResetStateBaseDir restores the base directory to the default StateBaseDir.
// For use in tests only.
func ResetStateBaseDir() {
	stateBaseDir = StateBaseDir
}

// ContainerMetadata holds the per-container metadata written to metadata.json.
type ContainerMetadata struct {
	ContainerID string `json:"container_id"`
	Pod         string `json:"pod"`
	Namespace   string `json:"namespace"`
	Profile     string `json:"profile"`
	Timestamp   string `json:"timestamp"`
}

// validPathComponent returns an error if s contains a path separator or "..",
// which would allow a caller to escape the state base directory.
func validPathComponent(s string) error {
	if strings.ContainsAny(s, "/\\") || s == ".." || strings.Contains(s, ".."+string(filepath.Separator)) {
		return fmt.Errorf("invalid path component %q: must not contain path separators or ..", s)
	}
	return nil
}

// WriteMetadata creates the per-container state directory and writes metadata.json.
// The directory layout is: {stateBaseDir}/{podUID}/{containerID}/metadata.json
// Directory permissions are 0700 (root-only); file permissions are 0600.
func WriteMetadata(podUID, containerID, pod, namespace, profile string) error {
	if err := validPathComponent(podUID); err != nil {
		return fmt.Errorf("WriteMetadata: %w", err)
	}
	if err := validPathComponent(containerID); err != nil {
		return fmt.Errorf("WriteMetadata: %w", err)
	}
	dir := filepath.Join(stateBaseDir, podUID, containerID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("creating state dir %s: %w", dir, err)
	}

	meta := ContainerMetadata{
		ContainerID: containerID,
		Pod:         pod,
		Namespace:   namespace,
		Profile:     profile,
		Timestamp:   time.Now().UTC().Format(time.RFC3339),
	}
	data, err := json.Marshal(meta)
	if err != nil {
		return fmt.Errorf("marshaling metadata: %w", err)
	}

	path := filepath.Join(dir, "metadata.json")
	if err := os.WriteFile(path, data, 0600); err != nil {
		return fmt.Errorf("writing metadata %s: %w", path, err)
	}
	return nil
}

// RemoveMetadata removes the container state directory and best-effort removes
// the pod-level parent directory if it is now empty.
// It is safe to call for non-existent paths (no error returned).
func RemoveMetadata(podUID, containerID string) error {
	if err := validPathComponent(podUID); err != nil {
		return fmt.Errorf("RemoveMetadata: %w", err)
	}
	if err := validPathComponent(containerID); err != nil {
		return fmt.Errorf("RemoveMetadata: %w", err)
	}
	containerDir := filepath.Join(stateBaseDir, podUID, containerID)
	if err := os.RemoveAll(containerDir); err != nil {
		return fmt.Errorf("removing state dir %s: %w", containerDir, err)
	}

	// Best-effort: remove pod parent dir if it is now empty.
	// os.Remove fails silently if the directory is non-empty — that is correct.
	podDir := filepath.Join(stateBaseDir, podUID)
	_ = os.Remove(podDir)

	return nil
}
