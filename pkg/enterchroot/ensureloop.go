package enterchroot

import (
	"fmt"
	"os"

	"github.com/rancher/k3os/pkg/insmod"
	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)

func mountProc() error {
	logrus.Debug("mkdir /proc")
	if err := os.MkdirAll("/proc", 0755); err != nil {
		return err
	}
	logrus.Debug("mount /proc")
	return unix.Mount("proc", "/proc", "proc", 0, "")
}

func mountDev() error {
	logrus.Debug("mkdir /dev")
	if err := os.MkdirAll("/dev", 0755); err != nil {
		return err
	}
	logrus.Debug("mounting /dev")
	return unix.Mount("none", "/dev", "devtmpfs", 0, "")
}

func umountSys() error {
	if err := unix.Unmount("/dev", 0); err != nil {
		return err
	}
	return unix.Unmount("/proc", 0)
}

func mknod(path string, mode uint32, major, minor int) error {
	if _, err := os.Stat(path); err == nil {
		return nil
	}

	dev := (major << 8) | (minor & 0xff) | ((minor & 0xfff00) << 12)
	logrus.Debugf("mknod %s", path)
	return unix.Mknod(path, mode, dev)
}

func ensureloop() error {
	if err := mountProc(); err != nil {
		return fmt.Errorf("failed to mount proc: %w", err)
	}
	if err := mountDev(); err != nil {
		return fmt.Errorf("failed to mount dev: %w", err)
	}

	// ignore error
	insmod.Load("loop")

	if err := mknod("/dev/loop-control", 0700|unix.S_IFCHR, 10, 237); err != nil {
		return err
	}
	for i := 0; i < 7; i++ {
		if err := mknod(fmt.Sprintf("/dev/loop%d", i), 0700|unix.S_IFBLK, 7, i); err != nil {
			return err
		}
	}

	return nil
}
