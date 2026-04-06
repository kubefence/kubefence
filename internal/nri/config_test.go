package nri_test

import (
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	nri "github.com/k8s-nono/nono-nri/internal/nri"
)

var _ = Describe("LoadConfig", func() {
	writeTempConfig := func(content string) string {
		GinkgoHelper()
		dir := GinkgoT().TempDir()
		path := filepath.Join(dir, "config.toml")
		err := os.WriteFile(path, []byte(content), 0o600)
		Expect(err).NotTo(HaveOccurred())
		return path
	}

	It("loads valid TOML config", func() {
		path := writeTempConfig(`runtime_classes = ["nono-runc", "nono-kata"]
default_profile = "default"
nono_bin_path = "/opt/nono/nono"
socket_path = "/var/run/nri/nri.sock"
`)
		cfg, err := nri.LoadConfig(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(cfg.RuntimeClasses).To(Equal([]string{"nono-runc", "nono-kata"}))
		Expect(cfg.DefaultProfile).To(Equal("default"))
		Expect(cfg.NonoBinPath).To(Equal("/opt/nono/nono"))
		Expect(cfg.SocketPath).To(Equal("/var/run/nri/nri.sock"))
	})

	It("returns error for missing file", func() {
		_, err := nri.LoadConfig("/nonexistent/path/config.toml")
		Expect(err).To(HaveOccurred())
	})

	It("returns error for empty runtime_classes", func() {
		path := writeTempConfig(`runtime_classes = []`)
		_, err := nri.LoadConfig(path)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("runtime_classes must not be empty"))
	})

	It("returns error for missing runtime_classes", func() {
		path := writeTempConfig(`default_profile = "test"`)
		_, err := nri.LoadConfig(path)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("runtime_classes must not be empty"))
	})

	It("ignores unknown TOML keys", func() {
		path := writeTempConfig(`runtime_classes = ["test"]
nono_bin_path = "/opt/nono/nono"
unknown_key = "value"
`)
		_, err := nri.LoadConfig(path)
		Expect(err).NotTo(HaveOccurred())
	})

	It("returns error for empty nono_bin_path when bind-mount delivery is used", func() {
		path := writeTempConfig(`runtime_classes = ["nono-runc"]
nono_bin_path = ""
`)
		_, err := nri.LoadConfig(path)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("nono_bin_path must not be empty"))
	})

	It("returns error for missing nono_bin_path when bind-mount delivery is used", func() {
		path := writeTempConfig(`runtime_classes = ["nono-runc"]
`)
		_, err := nri.LoadConfig(path)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("nono_bin_path must not be empty"))
	})

	It("allows missing nono_bin_path when all handlers are in vm_rootfs_classes", func() {
		path := writeTempConfig(`runtime_classes = ["kata-nono-qemu"]
vm_rootfs_classes = ["kata-nono-qemu"]
`)
		cfg, err := nri.LoadConfig(path)
		Expect(err).NotTo(HaveOccurred())
		Expect(cfg.IsVMRootfsClass("kata-nono-qemu")).To(BeTrue())
		Expect(cfg.IsVMRootfsClass("kata-qemu")).To(BeFalse())
	})

	It("returns error for missing nono_bin_path when some handlers use bind-mount", func() {
		path := writeTempConfig(`runtime_classes = ["nono-runc", "kata-nono-qemu"]
vm_rootfs_classes = ["kata-nono-qemu"]
`)
		_, err := nri.LoadConfig(path)
		Expect(err).To(HaveOccurred())
		Expect(err.Error()).To(ContainSubstring("nono_bin_path must not be empty"))
		Expect(err.Error()).To(ContainSubstring("nono-runc"))
	})
})
