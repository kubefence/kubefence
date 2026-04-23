package nri_test

import (
	api "github.com/containerd/nri/pkg/api"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	nri "github.com/k8s-nono/nono-nri/internal/nri"
)

var _ = Describe("BuildAdjustment", func() {
	DescribeTable("args prepend",
		func(originalArgs []string, profile string, expectedArgs []string) {
			ctr := &api.Container{Id: "ctr-x", Args: originalArgs}
			adj := nri.BuildAdjustment(ctr, profile, "/host/nono", false, nil)
			Expect(adj.Args).To(Equal(expectedArgs))
		},
		Entry("with existing args",
			[]string{"myapp", "--port", "8080"}, "strict",
			[]string{"/nono/nono", "wrap", "--profile", "strict", "--", "myapp", "--port", "8080"},
		),
		Entry("with nil args",
			nil, "default",
			[]string{"/nono/nono", "wrap", "--profile", "default", "--"},
		),
		Entry("with empty args slice",
			[]string{}, "permissive",
			[]string{"/nono/nono", "wrap", "--profile", "permissive", "--"},
		),
	)

	Describe("bind mount", func() {
		It("mounts the host directory to /nono so binary is accessible at /nono/nono", func() {
			ctr := &api.Container{Id: "ctr-1", Args: []string{"cmd"}}
			adj := nri.BuildAdjustment(ctr, "strict", "/usr/local/bin/nono", false, nil)

			Expect(adj.Mounts).To(HaveLen(1))
			m := adj.Mounts[0]
			Expect(m.Source).To(Equal("/usr/local/bin"))
			Expect(m.Destination).To(Equal("/nono"))
			Expect(m.Type).To(Equal("bind"))
			Expect(m.Options).To(ContainElements("bind", "ro", "rprivate"))
		})

		It("uses host bind-mount regardless of vmRootfs flag", func() {
			ctr := &api.Container{Id: "ctr-2", Args: []string{"cmd"}}
			adjStd := nri.BuildAdjustment(ctr, "default", "/opt/nono-nri/nono", false, nil)
			adjVM := nri.BuildAdjustment(ctr, "default", "/opt/nono-nri/nono", true, nil)

			Expect(adjStd.Mounts[0].Source).To(Equal("/opt/nono-nri"))
			Expect(adjVM.Mounts[0].Source).To(Equal("/opt/nono-nri"))
		})
	})

	Describe("env injection", func() {
		It("injects NONO_PROFILE with the resolved profile", func() {
			ctr := &api.Container{Id: "ctr-3", Args: []string{"cmd"}}
			adj := nri.BuildAdjustment(ctr, "strict", "/opt/nono-nri/nono", false, nil)

			envMap := make(map[string]string)
			for _, kv := range adj.Env {
				envMap[kv.Key] = kv.Value
			}
			Expect(envMap["NONO_PROFILE"]).To(Equal("strict"))
		})

		It("prepends /nono to the container's existing PATH", func() {
			ctr := &api.Container{
				Id:   "ctr-4",
				Args: []string{"cmd"},
				Env:  []string{"PATH=/custom/bin:/usr/bin", "HOME=/root"},
			}
			adj := nri.BuildAdjustment(ctr, "default", "/opt/nono-nri/nono", false, nil)

			envMap := make(map[string]string)
			for _, kv := range adj.Env {
				envMap[kv.Key] = kv.Value
			}
			Expect(envMap["PATH"]).To(Equal("/nono:/custom/bin:/usr/bin"))
		})

		It("uses the distribution default PATH when container has none", func() {
			ctr := &api.Container{Id: "ctr-5", Args: []string{"cmd"}}
			adj := nri.BuildAdjustment(ctr, "default", "/opt/nono-nri/nono", false, nil)

			envMap := make(map[string]string)
			for _, kv := range adj.Env {
				envMap[kv.Key] = kv.Value
			}
			Expect(envMap["PATH"]).To(HavePrefix("/nono:"))
			Expect(envMap["PATH"]).To(ContainSubstring("/usr/local/bin"))
		})
	})

	Describe("seccomp policy", func() {
		It("sets no seccomp policy when seccomp is nil", func() {
			ctr := &api.Container{Id: "ctr-6", Args: []string{"cmd"}}
			adj := nri.BuildAdjustment(ctr, "default", "/opt/nono-nri/nono", false, nil)
			// Linux field stays nil when no seccomp policy is requested.
			Expect(adj.Linux).To(BeNil())
		})

		It("sets the seccomp policy when seccomp is non-nil", func() {
			ctr := &api.Container{Id: "ctr-7", Args: []string{"cmd"}}
			policy := nri.BuildSeccompPolicy(nri.SeccompProfileRestricted)
			adj := nri.BuildAdjustment(ctr, "default", "/opt/nono-nri/nono", false, policy)

			Expect(adj.Linux).NotTo(BeNil())
			Expect(adj.Linux.SeccompPolicy).NotTo(BeNil())
			Expect(adj.Linux.SeccompPolicy.DefaultAction).To(Equal("SCMP_ACT_ERRNO"))
		})
	})

	Describe("ContainerNonoPath constant", func() {
		It("equals /nono/nono", func() {
			Expect(nri.ContainerNonoPath).To(Equal("/nono/nono"))
		})
	})
})
