//go:build linux

package nri

import (
	"fmt"
	"strconv"
	"strings"
	"syscall"
	"unsafe"
)

const (
	MinKernelMajor = 5
	MinKernelMinor = 13
)

// kernelVersionFn is the function used to detect the kernel version.
// It is a package-level variable to allow injection in tests.
var kernelVersionFn = defaultKernelVersion

// CheckKernel returns an error if the running kernel is older than 5.13.
// Returns nil if the kernel version meets the minimum requirement.
func CheckKernel() error {
	major, minor := kernelVersionFn()
	if major < MinKernelMajor || (major == MinKernelMajor && minor < MinKernelMinor) {
		return fmt.Errorf(
			"kernel %d.%d is too old: nono-nri requires Linux %d.%d+ for Landlock LSM support",
			major, minor, MinKernelMajor, MinKernelMinor,
		)
	}
	return nil
}

// defaultKernelVersion reads the kernel version via syscall.Uname and parses
// the major.minor version numbers from the Release field.
// On any parse failure (Uname error, unexpected format) it returns (0, 0),
// which causes CheckKernel to safely return an error rather than silently
// allowing an unsupported kernel through.
func defaultKernelVersion() (major, minor int) {
	var uname syscall.Utsname
	if err := syscall.Uname(&uname); err != nil {
		return 0, 0
	}
	// uname.Release is [65]int8 on amd64 and [65]byte on arm64. Reinterpret the
	// array as raw bytes via unsafe.Slice to avoid sign-extension on amd64.
	rel := unsafe.Slice((*byte)(unsafe.Pointer(&uname.Release[0])), len(uname.Release))
	releaseStr := strings.TrimRight(string(rel), "\x00")
	parts := strings.SplitN(releaseStr, ".", 3)
	if len(parts) < 2 {
		return 0, 0
	}
	major, _ = strconv.Atoi(parts[0])
	// Strip trailing non-digit suffix (e.g. "-generic", "-rc1", "+") from minor
	// by finding the first non-digit character rather than using TrimRight with
	// a character set (which would silently accept unexpected suffixes).
	minorRaw := parts[1]
	if idx := strings.IndexFunc(minorRaw, func(r rune) bool { return r < '0' || r > '9' }); idx >= 0 {
		minorRaw = minorRaw[:idx]
	}
	minor, _ = strconv.Atoi(minorRaw)
	return
}
