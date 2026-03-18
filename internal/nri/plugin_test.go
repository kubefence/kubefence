package nri_test

import (
	"bytes"
	"context"
	"encoding/json"
	"os"

	api "github.com/containerd/nri/pkg/api"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	nri "github.com/k8s-nono/nono-nri/internal/nri"
)

var _ = Describe("Plugin", func() {
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

	Describe("CreateContainer", func() {
		It("logs skip with all required fields for non-matching container", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc"},
				DefaultProfile: "default",
				NonoBinPath:    "/host/nono",
			}
			buf := &bytes.Buffer{}
			p := nri.NewPlugin(cfg, newBufLogger(buf))

			pod := &api.PodSandbox{
				RuntimeHandler: "runc",
				Namespace:      "prod",
				Name:           "web-abc",
				Annotations:    map[string]string{},
			}
			ctr := &api.Container{Id: "ctr-123"}

			adj, updates, err := p.CreateContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())
			Expect(adj).To(BeNil())
			Expect(updates).To(BeNil())

			var entry logEntry
			Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
			Expect(entry.Msg).To(Equal("skip"))
			Expect(entry.Decision).To(Equal("skip"))
			Expect(entry.ContainerID).To(Equal("ctr-123"))
			Expect(entry.Namespace).To(Equal("prod"))
			Expect(entry.Pod).To(Equal("web-abc"))
			Expect(entry.RuntimeHandler).To(Equal("runc"))
			Expect(entry.Reason).NotTo(BeEmpty())
		})

		It("returns ContainerAdjustment and logs injected for matching container", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc"},
				DefaultProfile: "default",
				NonoBinPath:    "/host/nono",
			}
			buf := &bytes.Buffer{}
			p := nri.NewPlugin(cfg, newBufLogger(buf))

			pod := &api.PodSandbox{
				RuntimeHandler: "nono-runc",
				Namespace:      "prod",
				Name:           "app-xyz",
				Annotations:    map[string]string{"nono.sh/profile": "strict"},
			}
			ctr := &api.Container{Id: "ctr-456"}

			adj, updates, err := p.CreateContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())
			Expect(adj).NotTo(BeNil())
			Expect(updates).To(BeNil())

			// Container has no args, so adj.Args = prefix only (5 elements)
			Expect(adj.Args).To(HaveLen(5))
			Expect(adj.Args[0]).To(Equal(nri.ContainerNonoPath))
			Expect(adj.Mounts).To(HaveLen(1))

			var entry logEntry
			Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
			Expect(entry.Msg).To(Equal("injected"))
			Expect(entry.Decision).To(Equal("inject"))
			Expect(entry.ContainerID).To(Equal("ctr-456"))
			Expect(entry.Namespace).To(Equal("prod"))
			Expect(entry.Pod).To(Equal("app-xyz"))
			Expect(entry.Profile).To(Equal("strict"))
			Expect(entry.RuntimeHandler).To(Equal("nono-runc"))
		})

		It("returns non-nil ContainerAdjustment with correct mount destination", func() {
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
				Name:           "test-pod",
				Annotations:    map[string]string{},
			}
			ctr := &api.Container{Id: "ctr-789"}

			adj, _, _ := p.CreateContainer(context.Background(), pod, ctr)
			Expect(adj).NotTo(BeNil())
			Expect(adj.Mounts).To(HaveLen(1))
			Expect(adj.Mounts[0].Destination).To(Equal("/nono"))
		})

		It("uses default profile when annotation absent", func() {
			cfg := &nri.Config{
				RuntimeClasses: []string{"nono-runc"},
				DefaultProfile: "fallback",
				NonoBinPath:    "/host/nono",
			}
			buf := &bytes.Buffer{}
			p := nri.NewPlugin(cfg, newBufLogger(buf))

			pod := &api.PodSandbox{
				RuntimeHandler: "nono-runc",
				Namespace:      "default",
				Name:           "test-pod",
				Annotations:    map[string]string{},
			}
			ctr := &api.Container{Id: "ctr-000"}

			_, _, err := p.CreateContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())

			var entry logEntry
			Expect(json.Unmarshal(buf.Bytes(), &entry)).To(Succeed())
			Expect(entry.Profile).To(Equal("fallback"))
			Expect(entry.Msg).To(Equal("injected"))
		})
	})

	Describe("RemoveContainer", func() {
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
			ctr := &api.Container{Id: "ctr-rem"}

			err := p.RemoveContainer(context.Background(), pod, ctr)
			Expect(err).NotTo(HaveOccurred())
		})
	})
})
