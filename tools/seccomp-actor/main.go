// seccomp-actor simulates an untrusted AI workload attempting dangerous
// operations. It runs as PID 1 (or a direct child) of the container so the
// seccomp filter applied at container start is in effect for every syscall.
//
// Each attempt is logged to stdout so `kubectl logs` shows exactly what the
// workload could and could not do. Exit code is always 0 so the pod
// completes cleanly and logs remain readable.
//
// Build (static, no CGO):
//
//	CGO_ENABLED=0 go build -o seccomp-actor ./tools/seccomp-actor/
package main

import (
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	cReset  = "\033[0m"
	cRed    = "\033[31m"
	cGreen  = "\033[32m"
	cYellow = "\033[33m"
	cBold   = "\033[1m"
	cDim    = "\033[2m"
)

func blocked(label, detail string) {
	fmt.Printf("  %sBLOCKED%s  %-45s %s\n", cRed, cReset, label, cDim+detail+cReset)
}
func allowed(label, detail string) {
	fmt.Printf("  %sALLOWED%s  %-45s %s\n", cGreen, cReset, label, cDim+detail+cReset)
}
func capgated(label, detail string) {
	fmt.Printf("  %sCAPGATED%s %-45s %s\n", cYellow, cReset, label, cDim+detail+cReset)
}
func section(s string) {
	fmt.Printf("\n%s%s%s\n", cBold, s, cReset)
}

func trySeccomp() {
	// Attempt to install a permissive seccomp filter (SECCOMP_SET_MODE_FILTER=1).
	// NULL prog → EFAULT if the syscall runs; EPERM if seccomp blocks it first.
	_, _, errno := syscall.RawSyscall(317, 1, 0, 0)
	switch errno {
	case syscall.EPERM:
		blocked("seccomp(SET_MODE_FILTER, NULL)", "cannot weaken/replace the active filter")
	case syscall.EFAULT:
		allowed("seccomp(SET_MODE_FILTER, NULL)", "handler ran → filter modification reachable")
	default:
		allowed("seccomp(SET_MODE_FILTER, NULL)", fmt.Sprintf("errno=%d", errno))
	}
}

func tryPtrace() {
	// PTRACE_PEEKDATA on pid=1 (init/sleep). ESRCH means the handler ran but
	// the target process wasn't traced; EPERM means seccomp stopped the call.
	_, _, errno := syscall.RawSyscall(101, 2, 1, 0)
	switch errno {
	case syscall.EPERM:
		blocked("ptrace(PTRACE_PEEKDATA, pid=1)", "cannot inspect init process memory")
	case syscall.ESRCH:
		allowed("ptrace(PTRACE_PEEKDATA, pid=1)", "handler ran → process inspection reachable")
	default:
		allowed("ptrace(PTRACE_PEEKDATA, pid=1)", fmt.Sprintf("errno=%d", errno))
	}
}

func tryIoUring() {
	// io_uring_setup(entries=1, params). A real params struct so the kernel
	// can actually create a ring — we close the fd immediately if it succeeds.
	var params [104]byte // sizeof(struct io_uring_params) on x86-64
	fd, _, errno := syscall.Syscall(425, 1, uintptr(unsafe.Pointer(&params[0])), 0)
	switch errno {
	case syscall.EPERM:
		blocked("io_uring_setup(entries=1)", "CVE-2022-2639 / CVE-2023-2598 vector unreachable")
	case 0:
		allowed("io_uring_setup(entries=1)", fmt.Sprintf("io_uring instance created fd=%d (container escape vector open)", fd))
		_ = syscall.Close(int(fd))
	default:
		allowed("io_uring_setup(entries=1)", fmt.Sprintf("handler ran, errno=%d", errno))
	}
}

func tryProcessVmReadv() {
	// process_vm_readv(pid=1, local_iov=NULL, liovcnt=1, ...).
	// NULL local_iov → EFAULT if handler runs; EPERM if seccomp blocks.
	_, _, errno := syscall.RawSyscall(310, 1, 0, 1)
	switch errno {
	case syscall.EPERM:
		blocked("process_vm_readv(pid=1)", "cannot read init process address space")
	case syscall.EFAULT:
		allowed("process_vm_readv(pid=1)", "handler ran → cross-process memory read reachable")
	default:
		allowed("process_vm_readv(pid=1)", fmt.Sprintf("errno=%d", errno))
	}
}

func tryBpf() {
	// bpf(BPF_PROG_LOAD=5, attr=NULL, size=0). EFAULT if handler runs.
	_, _, errno := syscall.RawSyscall(321, 5, 0, 0)
	switch errno {
	case syscall.EPERM:
		blocked("bpf(BPF_PROG_LOAD)", "cannot load eBPF programs")
	case syscall.EFAULT:
		allowed("bpf(BPF_PROG_LOAD)", "handler ran → eBPF loading reachable")
	default:
		allowed("bpf(BPF_PROG_LOAD)", fmt.Sprintf("errno=%d", errno))
	}
}

func tryUserfaultfd() {
	// userfaultfd(0xFFFF) — invalid flags so it never creates a usable fd.
	_, _, errno := syscall.RawSyscall(323, 0xFFFF, 0, 0)
	switch errno {
	case syscall.EPERM:
		blocked("userfaultfd(flags=0xFFFF)", "kernel exploit temporal primitive unavailable")
	case syscall.EINVAL:
		allowed("userfaultfd(flags=0xFFFF)", "handler ran → userfaultfd reachable (kernel exploit aid)")
	default:
		allowed("userfaultfd(flags=0xFFFF)", fmt.Sprintf("errno=%d", errno))
	}
}

func tryPidfdGetfd() {
	// pidfd_getfd(pidfd=-1, targetfd=0, flags=0). EBADF if handler runs.
	_, _, errno := syscall.RawSyscall(438, ^uintptr(0), 0, 0)
	switch errno {
	case syscall.EPERM:
		blocked("pidfd_getfd(pidfd=-1)", "cannot steal file descriptors from other processes")
	case syscall.EBADF:
		allowed("pidfd_getfd(pidfd=-1)", "handler ran → cross-process FD theft reachable")
	default:
		allowed("pidfd_getfd(pidfd=-1)", fmt.Sprintf("errno=%d", errno))
	}
}

func tryUnshare() {
	// unshare(CLONE_NEWUSER) — create a user namespace.
	// EPERM from seccomp vs EINVAL/0 from the kernel handler.
	_, _, errno := syscall.RawSyscall(272, 0x10000000, 0, 0)
	switch errno {
	case syscall.EPERM:
		blocked("unshare(CLONE_NEWUSER)", "cannot create user namespaces")
	case 0:
		allowed("unshare(CLONE_NEWUSER)", "user namespace created → privilege escalation path open")
	case syscall.EINVAL:
		// EINVAL from unshare(CLONE_NEWUSER): user namespaces are disabled in
		// the kernel config or the user.max_user_namespaces sysctl is 0.
		// The handler ran (not seccomp EPERM), but the operation is also
		// blocked at the kernel level for a different reason.
		allowed("unshare(CLONE_NEWUSER)", "handler ran (EINVAL: userns disabled or limit reached — not seccomp)")
	default:
		allowed("unshare(CLONE_NEWUSER)", fmt.Sprintf("handler ran, errno=%d", errno))
	}
}

func trySetns() {
	// setns(fd=-1, nstype=0). EBADF if handler runs; EPERM if seccomp blocks.
	_, _, errno := syscall.RawSyscall(308, ^uintptr(0), 0, 0)
	switch errno {
	case syscall.EPERM:
		blocked("setns(fd=-1)", "cannot join arbitrary namespaces")
	case syscall.EBADF:
		allowed("setns(fd=-1)", "handler ran → namespace joining reachable")
	default:
		allowed("setns(fd=-1)", fmt.Sprintf("errno=%d", errno))
	}
}

func tryMount() {
	// mount with NULL source. EFAULT before cap check on some kernels; EPERM
	// from seccomp or from no CAP_SYS_ADMIN. Cap-gated if unconfined also EPERM.
	_, _, errno := syscall.RawSyscall(165, 0, 0, 0)
	switch errno {
	case syscall.EPERM:
		// Ambiguous: could be seccomp or capability. We note both.
		capgated("mount(NULL, NULL, NULL)", "EPERM — seccomp or no CAP_SYS_ADMIN")
	case syscall.EFAULT:
		allowed("mount(NULL, NULL, NULL)", "handler ran → filesystem mount reachable (needs caps)")
	default:
		allowed("mount(NULL, NULL, NULL)", fmt.Sprintf("errno=%d", errno))
	}
}

func tryKexecLoad() {
	// kexec_load always needs CAP_SYS_BOOT; EPERM even without seccomp.
	_, _, errno := syscall.RawSyscall(246, 0, 0, 0)
	if errno == syscall.EPERM {
		capgated("kexec_load(0, 0, 0)", "EPERM — requires CAP_SYS_BOOT (seccomp also blocks this)")
	} else {
		allowed("kexec_load(0, 0, 0)", fmt.Sprintf("handler ran, errno=%d (unexpected)", errno))
	}
}

func tryInitModule() {
	// init_module always needs CAP_SYS_MODULE.
	_, _, errno := syscall.RawSyscall(175, 0, 0, 0)
	if errno == syscall.EPERM {
		capgated("init_module(NULL, 0)", "EPERM — requires CAP_SYS_MODULE (seccomp also blocks this)")
	} else {
		allowed("init_module(NULL, 0)", fmt.Sprintf("handler ran, errno=%d (unexpected)", errno))
	}
}

func main() {
	seccompProfile := os.Getenv("SECCOMP_PROFILE")
	if seccompProfile == "" {
		seccompProfile = "unknown"
	}

	fmt.Println()
	fmt.Printf("%s═══════════════════════════════════════════════════════════════════%s\n", cBold, cReset)
	fmt.Printf("%s seccomp-actor: untrusted AI workload escape simulation%s\n", cBold, cReset)
	fmt.Printf("%s profile: %-55s%s\n", cBold, seccompProfile, cReset)
	fmt.Printf("%s═══════════════════════════════════════════════════════════════════%s\n", cBold, cReset)
	fmt.Printf("%s BLOCKED = seccomp fired before the kernel handler ran (EPERM)%s\n", cDim, cReset)
	fmt.Printf("%s ALLOWED = kernel handler ran; operation is reachable%s\n", cDim, cReset)
	fmt.Printf("%s CAPGATED = EPERM even without seccomp (capability check wins)%s\n", cDim, cReset)

	section("── filter evasion ─────────────────────────────────────────────────────")
	trySeccomp()

	section("── cross-process attack primitives ────────────────────────────────────")
	tryPtrace()
	tryProcessVmReadv()
	tryPidfdGetfd()

	section("── privilege escalation ───────────────────────────────────────────────")
	tryUnshare()
	trySetns()
	tryMount()
	tryKexecLoad()
	tryInitModule()

	section("── kernel exploit primitives ──────────────────────────────────────────")
	tryIoUring()
	tryUserfaultfd()
	tryBpf()

	fmt.Println()
	fmt.Printf("%s═══════════════════════════════════════════════════════════════════%s\n", cBold, cReset)
	fmt.Println()
}
