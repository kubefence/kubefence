// seccomp-probe exercises a set of syscalls and reports whether each was
// blocked by seccomp (EPERM before the kernel handler ran) or reached the
// handler (any other errno, including success).
//
// The key insight: seccomp blocks a call with EPERM *before* the handler
// runs. So if we call a syscall with deliberately invalid arguments, a
// seccomp-blocked call returns EPERM, while a seccomp-allowed call returns
// whatever the kernel handler returns for bad args (EINVAL, EFAULT, EBADF,
// ESRCH, etc.).  When both profiled and unconfined pods return EPERM, the
// cause is a capability check inside the handler, not seccomp.
//
// Build (static, no CGO):
//
//	CGO_ENABLED=0 go build -o seccomp-probe ./tools/seccomp-probe/
package main

import (
	"fmt"
	"os"
	"syscall"
)

// ANSI helpers
const (
	cReset  = "\033[0m"
	cRed    = "\033[31m"
	cGreen  = "\033[32m"
	cYellow = "\033[33m"
	cBold   = "\033[1m"
	cDim    = "\033[2m"
)

func red(s string) string    { return cRed + s + cReset }
func green(s string) string  { return cGreen + s + cReset }
func yellow(s string) string { return cYellow + s + cReset }
func bold(s string) string   { return cBold + s + cReset }
func dim(s string) string    { return cDim + s + cReset }

// probe describes one syscall exercise.
type probe struct {
	// label is the human-readable call site printed in the table.
	label string
	// group controls the section header.
	// "delta"   — blocked by restricted, allowed by runtime-default
	// "both"    — blocked by both nono-nri profiles
	// "allowed" — allowed by all profiles
	group string
	// nr, a1-a3: syscall number and first three arguments.
	// We use deliberately invalid arguments so the call fails safely even
	// when seccomp allows it — we only want to observe the errno.
	nr         uintptr
	a1, a2, a3 uintptr
	// expected is the errno returned when seccomp ALLOWS this syscall.
	// The invalid args we supply cause the kernel handler to fail with this
	// errno.  If we see EPERM instead, seccomp blocked the call.
	// expected == syscall.EPERM means the syscall is cap-gated: the handler
	// itself always returns EPERM (no CAP_SYS_*) regardless of seccomp.
	expected syscall.Errno
	// note explains what "allowed" looks like for this syscall.
	note string
}

// errName returns a short symbolic name for common errnos.
func errName(e syscall.Errno) string {
	switch e {
	case syscall.EPERM:
		return "EPERM"
	case syscall.EINVAL:
		return "EINVAL"
	case syscall.EFAULT:
		return "EFAULT"
	case syscall.EBADF:
		return "EBADF"
	case syscall.ESRCH:
		return "ESRCH"
	case syscall.EACCES:
		return "EACCES"
	case syscall.ENOSYS:
		return "ENOSYS"
	case syscall.ENOMEM:
		return "ENOMEM"
	case 0:
		return "OK(0)"
	default:
		return fmt.Sprintf("errno=%d", int(e))
	}
}

var probes = []probe{
	// ── Blocked by restricted only — allowed by runtime-default ──────────────
	{
		label: "seccomp(SECCOMP_SET_MODE_FILTER=1, flags=0, prog=NULL)",
		group: "delta", nr: 317, a1: 1, a2: 0, a3: 0,
		expected: syscall.EFAULT,
		note:     "NULL prog pointer reaches handler → EFAULT",
	},
	{
		// PTRACE_PEEKDATA on a bogus pid is safe and unambiguous:
		// any process can call ptrace without root; only seccomp causes EPERM.
		label: "ptrace(PTRACE_PEEKDATA=2, pid=-1, addr=0, data=0)",
		group: "delta", nr: 101, a1: 2, a2: ^uintptr(0), a3: 0,
		expected: syscall.ESRCH,
		note:     "bogus PID → ESRCH from handler",
	},
	{
		label: "io_uring_setup(entries=0, params=NULL)",
		group: "delta", nr: 425, a1: 0, a2: 0, a3: 0,
		expected: syscall.EINVAL,
		note:     "entries=0 rejected by handler → EINVAL",
	},
	{
		label: "io_uring_enter(fd=-1, to_submit=0, min_complete=0, flags=0, sig=NULL)",
		group: "delta", nr: 426, a1: ^uintptr(0), a2: 0, a3: 0,
		expected: syscall.EBADF,
		note:     "bad fd → EBADF from handler",
	},
	{
		label: "io_uring_register(fd=-1, opcode=0, arg=NULL, nr_args=0)",
		group: "delta", nr: 427, a1: ^uintptr(0), a2: 0, a3: 0,
		expected: syscall.EBADF,
		note:     "bad fd → EBADF from handler",
	},
	{
		label: "pidfd_getfd(pidfd=-1, targetfd=0, flags=0)",
		group: "delta", nr: 438, a1: ^uintptr(0), a2: 0, a3: 0,
		expected: syscall.EBADF,
		note:     "bad pidfd → EBADF from handler",
	},

	// ── Blocked by both profiles — not in RuntimeDefault allowlist ────────────
	{
		label: "bpf(BPF_PROG_LOAD=5, attr=NULL, size=0)",
		group: "both", nr: 321, a1: 5, a2: 0, a3: 0,
		expected: syscall.EFAULT,
		note:     "NULL attr reaches handler → EFAULT",
	},
	{
		// liovcnt=1 with a NULL iovec forces EFAULT before the PID lookup.
		// liovcnt=0 would trivially succeed (nothing to copy) giving a
		// misleading OK — use liovcnt=1 so the handler reads the iovec ptr.
		label: "process_vm_readv(pid=1, lvec=NULL, liovcnt=1, ...)",
		group: "both", nr: 310, a1: 1, a2: 0, a3: 1,
		expected: syscall.EFAULT,
		note:     "NULL iovec pointer → EFAULT from handler",
	},
	{
		// flags=0xFFFF is intentionally invalid so the call never succeeds.
		label: "userfaultfd(flags=0xFFFF)",
		group: "both", nr: 323, a1: 0xFFFF, a2: 0, a3: 0,
		expected: syscall.EINVAL,
		note:     "invalid flags → EINVAL from handler",
	},
	{
		label: "perf_event_open(attr=NULL, pid=0, cpu=0, group_fd=-1, flags=0)",
		group: "both", nr: 298, a1: 0, a2: 0, a3: 0,
		// EFAULT from NULL attr if allowed; kernel may also return EACCES
		// when perf_event_paranoid > 2 (both are "allowed" outcomes).
		expected: syscall.EFAULT,
		note:     "NULL attr → EFAULT; or EACCES from perf_event_paranoid",
	},
	{
		label: "setns(fd=-1, nstype=0)",
		group: "both", nr: 308, a1: ^uintptr(0), a2: 0, a3: 0,
		expected: syscall.EBADF,
		note:     "bad fd → EBADF from handler",
	},
	{
		label: "unshare(CLONE_NEWUSER=0x10000000)",
		group: "both", nr: 272, a1: 0x10000000, a2: 0, a3: 0,
		// Success (0) or EPERM from userns limit — both mean seccomp allowed it.
		expected: 0,
		note:     "creates user namespace (may hit /proc/sys/user/max_user_namespaces limit)",
	},
	{
		// EPERM even unconfined — cap-gated, not seccomp.  Listed here to show
		// seccomp would also block it, but the cap check runs first.
		label: "kexec_load(entry=0, nr_segments=0, flags=0, segments=NULL)",
		group: "both", nr: 246, a1: 0, a2: 0, a3: 0,
		expected: syscall.EPERM,
		note:     "cap-gated: requires CAP_SYS_BOOT — EPERM from caps even without seccomp",
	},
	{
		label: "init_module(module_image=NULL, len=0, param_values=\"\")",
		group: "both", nr: 175, a1: 0, a2: 0, a3: 0,
		expected: syscall.EPERM,
		note:     "cap-gated: requires CAP_SYS_MODULE — EPERM from caps even without seccomp",
	},
	{
		label: "mount(source=\"\", target=\"\", fs=\"\", flags=0, data=NULL)",
		group: "both", nr: 165, a1: 0, a2: 0, a3: 0,
		// EFAULT when seccomp allows but no CAP_SYS_ADMIN — kernel dereferences
		// the NULL source pointer before checking caps on some kernel versions,
		// or EPERM after checking caps.  Both differ from seccomp's EPERM timing.
		expected: syscall.EFAULT,
		note:     "NULL source ptr → EFAULT (or EPERM from no CAP_SYS_ADMIN)",
	},

	// ── Allowed by all profiles — validates the allowlist is not over-broad ───
	{
		label: "read(fd=-1, buf=NULL, count=0)",
		group: "allowed", nr: 0, a1: ^uintptr(0), a2: 0, a3: 0,
		expected: syscall.EBADF,
		note:     "bad fd → EBADF",
	},
	{
		label: "arch_prctl(ARCH_GET_FS=0x1003, addr=NULL)",
		group: "allowed", nr: 158, a1: 0x1003, a2: 0, a3: 0,
		expected: syscall.EFAULT,
		note:     "NULL addr → EFAULT",
	},
	{
		label: "futex(uaddr=NULL, FUTEX_WAIT=0, val=0, timeout=NULL, ...)",
		group: "allowed", nr: 202, a1: 0, a2: 0, a3: 0,
		expected: syscall.EFAULT,
		note:     "NULL uaddr → EFAULT",
	},
	{
		label: "prctl(PR_GET_NAME=16, name=NULL, 0, 0, 0)",
		group: "allowed", nr: 157, a1: 16, a2: 0, a3: 0,
		expected: syscall.EFAULT,
		note:     "NULL name buffer → EFAULT",
	},
	{
		// clone3(uargs=NULL, size=0) → EINVAL from handler (size must be > 0).
		// Using clone3 (nr=435) avoids the clone fork-bomb risk where a NULL
		// stack clone can succeed and the child re-enters main().
		label: "clone3(uargs=NULL, size=0)",
		group: "allowed", nr: 435, a1: 0, a2: 0, a3: 0,
		expected: syscall.EINVAL,
		note:     "size=0 → EINVAL from handler",
	},
	{
		label: "mmap(addr=NULL, length=0, PROT_NONE=0, MAP_PRIVATE=2, fd=-1, 0)",
		group: "allowed", nr: 9, a1: 0, a2: 0, a3: 0,
		expected: syscall.EINVAL,
		note:     "length=0 → EINVAL",
	},
	{
		label: "landlock_create_ruleset(attr=NULL, size=0, flags=0)",
		group: "allowed", nr: 444, a1: 0, a2: 0, a3: 0,
		// Returns a fd (close it) or EOPNOTSUPP if Landlock is disabled.
		// Both mean seccomp allowed the call.
		expected: 0,
		note:     "returns ruleset fd or EOPNOTSUPP — either means seccomp allows it",
	},
}

func main() {
	fmt.Printf("\n%s\n", bold("═══════════════════════════════════════════════════════════════════════"))
	fmt.Printf("%s\n", bold(" seccomp-probe — syscall exercise set"))
	fmt.Printf("%s\n", dim(" EPERM = seccomp fired before the kernel handler ran"))
	fmt.Printf("%s\n", dim(" any other errno = handler ran; seccomp allowed the call"))
	fmt.Printf("%s\n\n", bold("═══════════════════════════════════════════════════════════════════════"))

	section := ""
	for _, p := range probes {
		if p.group != section {
			section = p.group
			switch section {
			case "delta":
				fmt.Printf("\n%s\n", dim("── restricted only: BLOCKED here, allowed by runtime-default ─────────────"))
			case "both":
				fmt.Printf("\n%s\n", dim("── blocked by both nono-nri profiles ─────────────────────────────────────"))
			case "allowed":
				fmt.Printf("\n%s\n", dim("── allowed by all profiles — allowlist is not over-broad ─────────────────"))
			}
		}

		// Use Syscall6 throughout so r1 is available to close any fd that
		// a successful call may have created (userfaultfd, landlock).
		r1, _, errno := syscall.Syscall6(p.nr, p.a1, p.a2, p.a3, 0, 0, 0)
		if errno == 0 && int(r1) > 2 {
			_ = syscall.Close(int(r1))
		}

		fmt.Printf("\n  %s\n", bold(p.label))

		switch {
		case errno == syscall.EPERM && p.expected == syscall.EPERM:
			// Cap-gated: EPERM expected even without seccomp.
			fmt.Printf("  result: %s\n", yellow("EPERM  (cap-gated — EPERM even unconfined; not a seccomp signal)"))
			fmt.Printf("  note:   %s\n", dim(p.note))

		case errno == syscall.EPERM:
			// EPERM when we expected something else → seccomp fired.
			fmt.Printf("  result: %s\n", red("EPERM  ← SECCOMP BLOCKED (handler never ran)"))
			fmt.Printf("  note:   %s\n", dim("expected when allowed: "+p.note))

		case errno == syscall.EACCES && p.nr == 298:
			// perf_event_open: EACCES from perf_event_paranoid, not seccomp.
			fmt.Printf("  result: %s\n", green("EACCES  (allowed by seccomp; blocked by perf_event_paranoid sysctl)"))
			fmt.Printf("  note:   %s\n", dim(p.note))

		default:
			// Any non-EPERM errno: seccomp allowed the call, kernel handler ran.
			name := errName(errno)
			if errno == 0 {
				fmt.Printf("  result: %s\n", green("0 / OK  (allowed; syscall succeeded — side effect contained)"))
			} else {
				fmt.Printf("  result: %s  %s\n",
					green("allowed — "+name),
					dim("("+errno.Error()+")"),
				)
			}
			fmt.Printf("  note:   %s\n", dim(p.note))
		}
	}

	fmt.Printf("\n%s\n\n", bold("═══════════════════════════════════════════════════════════════════════"))
	os.Exit(0)
}
