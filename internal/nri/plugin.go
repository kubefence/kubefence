package nri

import (
	"context"
	"log/slog"

	api "github.com/containerd/nri/pkg/api"
)

// Plugin implements the NRI plugin interface for nono-nri.
// It intercepts container creation events, decides whether to sandbox the
// container based on the pod's RuntimeHandler, and logs structured decisions
// with all CORE-04 required fields.
type Plugin struct {
	Config *Config
	Log    *slog.Logger
}

// NewPlugin constructs a Plugin with the given config and logger.
func NewPlugin(cfg *Config, logger *slog.Logger) *Plugin {
	return &Plugin{Config: cfg, Log: logger}
}

// CreateContainer is called by the NRI runtime before each container is created.
// It resolves the nono profile for the pod, checks whether the container should
// be sandboxed, and logs the resulting decision with all CORE-04 fields.
// For sandboxed containers it returns a ContainerAdjustment that prepends the
// nono wrapper command and bind-mounts the nono binary into the container.
func (p *Plugin) CreateContainer(
	ctx context.Context,
	pod *api.PodSandbox,
	ctr *api.Container,
) (*api.ContainerAdjustment, []*api.ContainerUpdate, error) {
	handler := pod.GetRuntimeHandler()
	namespace := pod.GetNamespace()
	podName := pod.GetName()
	ctrID := ctr.GetId()
	profile := ResolveProfile(pod, p.Config)

	if !ShouldSandbox(pod, p.Config) {
		p.Log.Info("skip",
			"decision", "skip",
			"reason", SkipReason(pod),
			"container_id", ctrID,
			"namespace", namespace,
			"pod", podName,
			"profile", profile,
			"runtime_handler", handler,
		)
		return nil, nil, nil
	}

	adj := BuildAdjustment(ctr, profile, p.Config.NonoBinPath)
	if err := WriteMetadata(pod.GetUid(), ctrID, podName, namespace, profile); err != nil {
		p.Log.Warn("failed to write state metadata", "container_id", ctrID, "error", err)
	}
	p.Log.Info("injected",
		"decision", "inject",
		"container_id", ctrID,
		"namespace", namespace,
		"pod", podName,
		"profile", profile,
		"runtime_handler", handler,
	)
	return adj, nil, nil
}

// RemoveContainer is called by the NRI runtime after a container is removed.
// It cleans up the container's state directory.
// Signature matches stub.RemoveContainerInterface: returns error only (no ContainerUpdate).
func (p *Plugin) RemoveContainer(
	ctx context.Context,
	pod *api.PodSandbox,
	ctr *api.Container,
) error {
	p.Log.Info("container-removed",
		"container_id", ctr.GetId(),
		"pod", pod.GetName(),
		"namespace", pod.GetNamespace(),
	)
	if err := RemoveMetadata(pod.GetUid(), ctr.GetId()); err != nil {
		p.Log.Warn("failed to remove state metadata", "container_id", ctr.GetId(), "error", err)
	}
	return nil
}
