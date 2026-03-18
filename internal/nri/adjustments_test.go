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
			adj := nri.BuildAdjustment(ctr, profile, "/host/nono")
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

	Describe("readonly bind mount", func() {
		It("adds exactly one mount with correct fields and options", func() {
			ctr := &api.Container{Id: "ctr-3", Args: []string{"cmd"}}
			adj := nri.BuildAdjustment(ctr, "strict", "/usr/local/bin/nono")

			Expect(adj.Mounts).To(HaveLen(1))
			m := adj.Mounts[0]
			Expect(m.Source).To(Equal("/usr/local/bin/nono"))
			Expect(m.Destination).To(Equal(nri.ContainerNonoPath))
			Expect(m.Type).To(Equal("bind"))
			Expect(m.Options).To(ContainElements("bind", "ro", "rprivate"))
		})
	})

	Describe("ContainerNonoPath constant", func() {
		It("equals /nono/nono", func() {
			Expect(nri.ContainerNonoPath).To(Equal("/nono/nono"))
		})
	})
})
