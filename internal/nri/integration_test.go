package nri_test

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"

	api "github.com/containerd/nri/pkg/api"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	nri "github.com/k8s-nono/nono-nri/internal/nri"
)

// integrationLogEntry is used to parse structured JSON log output in integration tests.
type integrationLogEntry struct {
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

var _ = Describe("Integration", func() {
	Context("Full CreateContainer flow for matching pod", func() {
		It("logs injection-pending with all required CORE-04 fields", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc", "nono-kata"},
				DefaultProfile: "default",
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
			Expect(err).To(BeNil())
			Expect(adj).To(BeNil())
			Expect(updates).To(BeNil())

			var entry integrationLogEntry
			Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
			Expect(entry.Msg).To(Equal("injection-pending"))
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
			Expect(err).To(BeNil())
			Expect(adj).To(BeNil())

			var entry integrationLogEntry
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
			Expect(err).To(BeNil())

			var entry integrationLogEntry
			Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
			Expect(entry.Profile).To(Equal("permissive"))
		})
	})

	Context("Multiple containers in sequence", func() {
		It("correctly classifies 2 matching and 1 non-matching container", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc"},
				DefaultProfile: "default",
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

			_, _, err := p.CreateContainer(context.Background(), matchingPod1, ctr1)
			Expect(err).To(BeNil())
			_, _, err = p.CreateContainer(context.Background(), matchingPod2, ctr2)
			Expect(err).To(BeNil())
			_, _, err = p.CreateContainer(context.Background(), nonMatchingPod, ctr3)
			Expect(err).To(BeNil())

			// Parse all 3 log lines
			lines := strings.Split(strings.TrimRight(buf.String(), "\n"), "\n")
			Expect(lines).To(HaveLen(3))

			injectCount := 0
			skipCount := 0
			containerIDs := map[string]bool{}

			for _, line := range lines {
				var entry integrationLogEntry
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
			Expect(err).To(BeNil())
		})

		It("returns error when version function reports old kernel", func() {
			nri.SetKernelVersionFunc(func() (int, int) { return 4, 18 })
			defer nri.ResetKernelVersionFunc()

			err := nri.CheckKernel()
			Expect(err).NotTo(BeNil())
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

			updates, err := p.RemoveContainer(context.Background(), pod, ctr)
			Expect(err).To(BeNil())
			Expect(updates).To(BeNil())
		})
	})
})
