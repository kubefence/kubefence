package nri_test

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	nri "github.com/k8s-nono/nono-nri/internal/nri"
)

var _ = Describe("BuildSeccompPolicy", func() {
	It("returns nil for empty profile", func() {
		Expect(nri.BuildSeccompPolicy("")).To(BeNil())
	})

	It("returns nil for unknown profile", func() {
		Expect(nri.BuildSeccompPolicy("nonexistent")).To(BeNil())
	})

	Describe("runtime-default", func() {
		It("returns a policy with SCMP_ACT_ERRNO default action", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRuntimeDefault)
			Expect(p).NotTo(BeNil())
			Expect(p.DefaultAction).To(Equal("SCMP_ACT_ERRNO"))
		})

		It("declares only SCMP_ARCH_X86_64", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRuntimeDefault)
			Expect(p.Architectures).To(ConsistOf("SCMP_ARCH_X86_64"))
		})

		It("has a single SCMP_ACT_ALLOW rule covering all allowed syscalls", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRuntimeDefault)
			Expect(p.Syscalls).To(HaveLen(1))
			Expect(p.Syscalls[0].Action).To(Equal("SCMP_ACT_ALLOW"))
			Expect(p.Syscalls[0].Names).NotTo(BeEmpty())
		})

		It("includes io_uring syscalls (allowed in runtime-default)", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRuntimeDefault)
			names := p.Syscalls[0].Names
			Expect(names).To(ContainElement("io_uring_setup"))
			Expect(names).To(ContainElement("io_uring_enter"))
			Expect(names).To(ContainElement("io_uring_register"))
		})

		It("includes ptrace and seccomp syscalls (allowed in runtime-default)", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRuntimeDefault)
			names := p.Syscalls[0].Names
			Expect(names).To(ContainElement("ptrace"))
			Expect(names).To(ContainElement("seccomp"))
		})
	})

	Describe("restricted", func() {
		It("returns a policy with SCMP_ACT_ERRNO default action", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRestricted)
			Expect(p).NotTo(BeNil())
			Expect(p.DefaultAction).To(Equal("SCMP_ACT_ERRNO"))
		})

		It("declares only SCMP_ARCH_X86_64", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRestricted)
			Expect(p.Architectures).To(ConsistOf("SCMP_ARCH_X86_64"))
		})

		It("blocks io_uring syscalls", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRestricted)
			names := p.Syscalls[0].Names
			Expect(names).NotTo(ContainElement("io_uring_setup"))
			Expect(names).NotTo(ContainElement("io_uring_enter"))
			Expect(names).NotTo(ContainElement("io_uring_register"))
		})

		It("blocks ptrace", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRestricted)
			Expect(p.Syscalls[0].Names).NotTo(ContainElement("ptrace"))
		})

		It("blocks the seccomp syscall to prevent filter removal", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRestricted)
			Expect(p.Syscalls[0].Names).NotTo(ContainElement("seccomp"))
		})

		It("blocks pidfd_getfd", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRestricted)
			Expect(p.Syscalls[0].Names).NotTo(ContainElement("pidfd_getfd"))
		})

		It("still allows common syscalls not in the block list", func() {
			p := nri.BuildSeccompPolicy(nri.SeccompProfileRestricted)
			names := p.Syscalls[0].Names
			Expect(names).To(ContainElement("read"))
			Expect(names).To(ContainElement("write"))
			Expect(names).To(ContainElement("execve"))
			Expect(names).To(ContainElement("futex"))
		})

		It("has fewer allowed syscalls than runtime-default", func() {
			rd := nri.BuildSeccompPolicy(nri.SeccompProfileRuntimeDefault)
			r := nri.BuildSeccompPolicy(nri.SeccompProfileRestricted)
			Expect(len(r.Syscalls[0].Names)).To(BeNumerically("<", len(rd.Syscalls[0].Names)))
		})
	})
})
