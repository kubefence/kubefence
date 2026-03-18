package nri_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"

	api "github.com/containerd/nri/pkg/api"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	nri "github.com/k8s-nono/nono-nri/internal/nri"
)

var _ = Describe("Integration", func() {
	var tmpDir string

	BeforeEach(func() {
		var err error
		tmpDir, err = os.MkdirTemp("", "nono-state-*")
		Expect(err).NotTo(HaveOccurred())
		nri.SetStateBaseDir(tmpDir)
	})

	AfterEach(func() {
		nri.ResetStateBaseDir()
		os.RemoveAll(tmpDir)
	})

	Context("Full CreateContainer flow for matching pod", func() {
		It("returns non-nil ContainerAdjustment and logs injected with all required CORE-04 fields", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc", "nono-kata"},
				DefaultProfile: "default",
				NonoBinPath:    "/host/nono",
			}
			buf := &bytes.Buffer{}
			p := nri.NewPlugin(cfg, newBufLogger(buf))

			pod := &api.PodSandbox{
				RuntimeHandler: "nono-runc",
				Namespace:      "production",
				Name:           "web-server-abc",
				Annotations:    map[string]string{"nono.sh/profile": "strict"},
			}
			ctr := &api.Container{Id: "container-789"}

			adj, updates, err := p.CreateContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())
			Expect(adj).NotTo(BeNil())
			Expect(updates).To(BeNil())

			Expect(adj.Args[0]).To(Equal("/nono/nono"))
			Expect(adj.Mounts).To(HaveLen(1))

			var entry logEntry
			Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
			Expect(entry.Msg).To(Equal("injected"))
			Expect(entry.Decision).To(Equal("inject"))
			Expect(entry.ContainerID).To(Equal("container-789"))
			Expect(entry.Namespace).To(Equal("production"))
			Expect(entry.Pod).To(Equal("web-server-abc"))
			Expect(entry.Profile).To(Equal("strict"))
			Expect(entry.RuntimeHandler).To(Equal("nono-runc"))
			Expect(entry.Time).NotTo(BeEmpty())
			Expect(strings.ToUpper(entry.Level)).To(ContainSubstring("INFO"))
		})
	})

	Context("Full CreateContainer flow for non-matching pod", func() {
		It("logs skip with reason and all required fields", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc", "nono-kata"},
				DefaultProfile: "default",
				NonoBinPath:    "/host/nono",
			}
			buf := &bytes.Buffer{}
			p := nri.NewPlugin(cfg, newBufLogger(buf))

			pod := &api.PodSandbox{
				RuntimeHandler: "runc",
				Namespace:      "kube-system",
				Name:           "coredns-def",
				Annotations:    map[string]string{},
			}
			ctr := &api.Container{Id: "container-456"}

			adj, _, err := p.CreateContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())
			Expect(adj).To(BeNil())

			var entry logEntry
			Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
			Expect(entry.Msg).To(Equal("skip"))
			Expect(entry.Decision).To(Equal("skip"))
			Expect(entry.Reason).NotTo(BeEmpty())
			Expect(entry.ContainerID).To(Equal("container-456"))
			Expect(entry.Namespace).To(Equal("kube-system"))
			Expect(entry.Pod).To(Equal("coredns-def"))
			Expect(entry.RuntimeHandler).To(Equal("runc"))
		})
	})

	Context("Full CreateContainer flow with default profile fallback", func() {
		It("uses DefaultProfile when no annotation is present", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc", "nono-kata"},
				DefaultProfile: "permissive",
				NonoBinPath:    "/host/nono",
			}
			buf := &bytes.Buffer{}
			p := nri.NewPlugin(cfg, newBufLogger(buf))

			pod := &api.PodSandbox{
				RuntimeHandler: "nono-runc",
				Namespace:      "staging",
				Name:           "worker-ghi",
				Annotations:    map[string]string{},
			}
			ctr := &api.Container{Id: "container-111"}

			_, _, err := p.CreateContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())

			var entry logEntry
			Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
			Expect(entry.Profile).To(Equal("permissive"))
			Expect(entry.Msg).To(Equal("injected"))
		})
	})

	Context("Multiple containers in sequence", func() {
		It("correctly classifies 2 matching and 1 non-matching container", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc"},
				DefaultProfile: "default",
				NonoBinPath:    "/host/nono",
			}
			buf := &bytes.Buffer{}
			p := nri.NewPlugin(cfg, newBufLogger(buf))

			// Two matching pods
			matchingPod1 := &api.PodSandbox{
				RuntimeHandler: "nono-runc",
				Namespace:      "prod",
				Name:           "app-one",
				Annotations:    map[string]string{},
			}
			matchingPod2 := &api.PodSandbox{
				RuntimeHandler: "nono-runc",
				Namespace:      "prod",
				Name:           "app-two",
				Annotations:    map[string]string{},
			}
			// One non-matching pod
			nonMatchingPod := &api.PodSandbox{
				RuntimeHandler: "runc",
				Namespace:      "kube-system",
				Name:           "system-pod",
				Annotations:    map[string]string{},
			}

			ctr1 := &api.Container{Id: "container-seq-1"}
			ctr2 := &api.Container{Id: "container-seq-2"}
			ctr3 := &api.Container{Id: "container-seq-3"}

			adj1, _, err := p.CreateContainer(context.Background(), matchingPod1, ctr1)
			Expect(err).NotTo(HaveOccurred())
			Expect(adj1).NotTo(BeNil())

			adj2, _, err := p.CreateContainer(context.Background(), matchingPod2, ctr2)
			Expect(err).NotTo(HaveOccurred())
			Expect(adj2).NotTo(BeNil())

			adj3, _, err := p.CreateContainer(context.Background(), nonMatchingPod, ctr3)
			Expect(err).NotTo(HaveOccurred())
			Expect(adj3).To(BeNil())

			// Parse all 3 log lines
			lines := strings.Split(strings.TrimRight(buf.String(), "\n"), "\n")
			Expect(lines).To(HaveLen(3))

			injectCount := 0
			skipCount := 0
			containerIDs := map[string]bool{}

			for _, line := range lines {
				var entry logEntry
				Expect(json.Unmarshal([]byte(line), &entry)).To(Succeed())
				switch entry.Decision {
				case "inject":
					injectCount++
				case "skip":
					skipCount++
				}
				Expect(entry.ContainerID).NotTo(BeEmpty())
				containerIDs[entry.ContainerID] = true
			}

			Expect(injectCount).To(Equal(2))
			Expect(skipCount).To(Equal(1))
			// Each container ID must be unique
			Expect(containerIDs).To(HaveLen(3))
		})
	})

	Context("CheckKernel on real host", func() {
		It("returns nil on current kernel (expected >= 5.13)", func() {
			nri.ResetKernelVersionFunc()
			err := nri.CheckKernel()
			Expect(err).NotTo(HaveOccurred())
		})

		It("returns error when version function reports old kernel", func() {
			nri.SetKernelVersionFunc(func() (int, int) { return 4, 18 })
			defer nri.ResetKernelVersionFunc()

			err := nri.CheckKernel()
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("too old"))
			Expect(err.Error()).To(ContainSubstring("5.13"))
			Expect(err.Error()).To(ContainSubstring("4.18"))
		})
	})

	Context("RemoveContainer flow", func() {
		It("returns nil updates and nil error", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc"},
				DefaultProfile: "default",
			}
			buf := &bytes.Buffer{}
			p := nri.NewPlugin(cfg, newBufLogger(buf))

			pod := &api.PodSandbox{
				Name:      "test-pod",
				Namespace: "default",
			}
			ctr := &api.Container{Id: "container-remove-1"}

			err := p.RemoveContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())
		})
	})

	Context("RemoveContainer cleans up state dir", func() {
		It("removes state directory after CreateContainer wrote it", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc"},
				DefaultProfile: "default",
				NonoBinPath:    "/host/nono",
			}
			buf := &bytes.Buffer{}
			p := nri.NewPlugin(cfg, newBufLogger(buf))

			pod := &api.PodSandbox{
				RuntimeHandler: "nono-runc",
				Namespace:      "default",
				Name:           "state-test-pod",
				Uid:            "pod-uid-abc",
				Annotations:    map[string]string{},
			}
			ctr := &api.Container{Id: "ctr-state-1"}

			// CreateContainer should write state
			adj, _, err := p.CreateContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())
			Expect(adj).NotTo(BeNil())

			// Verify state directory was created
			stateDir := filepath.Join(tmpDir, "pod-uid-abc", "ctr-state-1")
			_, statErr := os.Stat(stateDir)
			Expect(statErr).NotTo(HaveOccurred())

			// RemoveContainer should clean up state
			err = p.RemoveContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())

			// Verify state directory is removed
			_, statErr = os.Stat(stateDir)
			Expect(os.IsNotExist(statErr)).To(BeTrue())
		})
	})
})

var _ = Describe("End-to-end injection lifecycle", func() {
	var tmpDir string

	BeforeEach(func() {
		var err error
		tmpDir, err = os.MkdirTemp("", "nono-e2e-*")
		Expect(err).NotTo(HaveOccurred())
		nri.SetStateBaseDir(tmpDir)
	})

	AfterEach(func() {
		nri.ResetStateBaseDir()
		os.RemoveAll(tmpDir)
	})

	It("full lifecycle for a sandboxed container", func() {
		cfg := &nri.Config{
			RuntimeClasses: []string{"nono-runc"},
			DefaultProfile: "default",
			NonoBinPath:    "/host/bin/nono",
		}
		buf := &bytes.Buffer{}
		p := nri.NewPlugin(cfg, newBufLogger(buf))

		pod := &api.PodSandbox{
			RuntimeHandler: "nono-runc",
			Namespace:      "prod",
			Name:           "app-pod",
			Uid:            "pod-uid-e2e",
			Annotations:    map[string]string{"nono.sh/profile": "strict"},
		}
		ctr := &api.Container{
			Id:   "ctr-e2e-1",
			Args: []string{"python", "app.py", "--port", "8080"},
		}

		adj, updates, err := p.CreateContainer(context.Background(), pod, ctr)
		Expect(err).NotTo(HaveOccurred())
		Expect(updates).To(BeNil())
		Expect(adj).NotTo(BeNil())

		// Verify args are fully wrapped
		Expect(adj.Args).To(Equal([]string{
			"/nono/nono", "wrap", "--profile", "strict", "--",
			"python", "app.py", "--port", "8080",
		}))

		// Verify mount is present and correct
		Expect(adj.Mounts).To(HaveLen(1))
		Expect(adj.Mounts[0].Source).To(Equal("/host/bin"))
		Expect(adj.Mounts[0].Destination).To(Equal("/nono"))
		Expect(adj.Mounts[0].Type).To(Equal("bind"))
		Expect(adj.Mounts[0].Options).To(ContainElements("bind", "ro", "rprivate"))

		// Verify metadata.json was written
		metaPath := filepath.Join(tmpDir, "pod-uid-e2e", "ctr-e2e-1", "metadata.json")
		_, statErr := os.Stat(metaPath)
		Expect(statErr).NotTo(HaveOccurred())

		// Read and unmarshal metadata
		data, readErr := os.ReadFile(metaPath)
		Expect(readErr).NotTo(HaveOccurred())
		var meta nri.ContainerMetadata
		Expect(json.Unmarshal(data, &meta)).To(Succeed())
		Expect(meta.ContainerID).To(Equal("ctr-e2e-1"))
		Expect(meta.Pod).To(Equal("app-pod"))
		Expect(meta.Namespace).To(Equal("prod"))
		Expect(meta.Profile).To(Equal("strict"))
		Expect(meta.Timestamp).NotTo(BeEmpty())

		// Verify log output contains "injected" and required CORE-04 fields
		var entry logEntry
		Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
		Expect(entry.Msg).To(Equal("injected"))
		Expect(entry.ContainerID).To(Equal("ctr-e2e-1"))

		// RemoveContainer should clean up state dir
		err = p.RemoveContainer(context.Background(), pod, ctr)
		Expect(err).NotTo(HaveOccurred())

		// Container dir should be gone
		ctrDir := filepath.Join(tmpDir, "pod-uid-e2e", "ctr-e2e-1")
		_, statErr = os.Stat(ctrDir)
		Expect(errors.Is(statErr, os.ErrNotExist)).To(BeTrue())

		// Pod dir should also be gone (was the only container)
		podDir := filepath.Join(tmpDir, "pod-uid-e2e")
		_, statErr = os.Stat(podDir)
		Expect(errors.Is(statErr, os.ErrNotExist)).To(BeTrue())
	})

	It("non-sandboxed container is completely untouched", func() {
		cfg := &nri.Config{
			RuntimeClasses: []string{"nono-runc"},
			DefaultProfile: "default",
			NonoBinPath:    "/host/bin/nono",
		}
		buf := &bytes.Buffer{}
		p := nri.NewPlugin(cfg, newBufLogger(buf))

		podUID := "pod-uid-skip-1"
		pod := &api.PodSandbox{
			RuntimeHandler: "runc", // not in RuntimeClasses
			Namespace:      "kube-system",
			Name:           "coredns-skip",
			Uid:            podUID,
			Annotations:    map[string]string{},
		}
		ctr := &api.Container{Id: "ctr-skip-1"}

		adj, updates, err := p.CreateContainer(context.Background(), pod, ctr)
		Expect(err).NotTo(HaveOccurred())
		Expect(adj).To(BeNil())
		Expect(updates).To(BeNil())

		// No state dir should have been created
		_, statErr := os.Stat(filepath.Join(tmpDir, podUID))
		Expect(errors.Is(statErr, os.ErrNotExist)).To(BeTrue())

		// Log should contain "skip"
		var entry logEntry
		Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
		Expect(entry.Msg).To(Equal("skip"))
	})

	It("multiple containers across pods with mixed injection", func() {
		cfg := &nri.Config{
			RuntimeClasses: []string{"nono-runc"},
			DefaultProfile: "default",
			NonoBinPath:    "/host/bin/nono",
		}
		buf := &bytes.Buffer{}
		p := nri.NewPlugin(cfg, newBufLogger(buf))

		matchingPod := &api.PodSandbox{
			RuntimeHandler: "nono-runc",
			Namespace:      "prod",
			Name:           "matching-pod",
			Uid:            "pod-uid-match",
			Annotations:    map[string]string{},
		}
		nonMatchingPod := &api.PodSandbox{
			RuntimeHandler: "runc",
			Namespace:      "kube-system",
			Name:           "non-matching-pod",
			Uid:            "pod-uid-nomatch",
			Annotations:    map[string]string{},
		}

		matchingCtr := &api.Container{Id: "ctr-match-1"}
		nonMatchingCtr := &api.Container{Id: "ctr-nomatch-1"}

		// CreateContainer for matching: adj non-nil, state written
		adj1, _, err := p.CreateContainer(context.Background(), matchingPod, matchingCtr)
		Expect(err).NotTo(HaveOccurred())
		Expect(adj1).NotTo(BeNil())
		matchStateDir := filepath.Join(tmpDir, "pod-uid-match", "ctr-match-1")
		_, statErr := os.Stat(matchStateDir)
		Expect(statErr).NotTo(HaveOccurred())

		// CreateContainer for non-matching: adj nil, no state
		adj2, _, err := p.CreateContainer(context.Background(), nonMatchingPod, nonMatchingCtr)
		Expect(err).NotTo(HaveOccurred())
		Expect(adj2).To(BeNil())
		_, statErr = os.Stat(filepath.Join(tmpDir, "pod-uid-nomatch"))
		Expect(errors.Is(statErr, os.ErrNotExist)).To(BeTrue())

		// RemoveContainer for matching: state cleaned
		err = p.RemoveContainer(context.Background(), matchingPod, matchingCtr)
		Expect(err).NotTo(HaveOccurred())
		_, statErr = os.Stat(matchStateDir)
		Expect(errors.Is(statErr, os.ErrNotExist)).To(BeTrue())

		// RemoveContainer for non-matching: no error (RemoveMetadata is safe on non-existent paths)
		err = p.RemoveContainer(context.Background(), nonMatchingPod, nonMatchingCtr)
		Expect(err).NotTo(HaveOccurred())
	})
})
