package enterchroot

import (
	"errors"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/rancher/k3os/pkg/insmod"
	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
	"gopkg.in/freddierice/go-losetup.v1"
)

var (
	usr          = "usr"
	symlinks     = []string{"lib", "lib64", "bin", "sbin"}
	DebugCmdline = ""
)

func isDebug() bool {
	if os.Getenv("ENTER_DEBUG") == "true" {
		return true
	}

	if DebugCmdline == "" {
		return false
	}

	bytes, err := ioutil.ReadFile("/proc/cmdline")
	if err != nil {
		// ignore error
		return false
	}
	for _, word := range strings.Fields(string(bytes)) {
		if word == DebugCmdline {
			return true
		}
	}

	return false
}

func Mount() error {
	if err := ensureloop(); err != nil {
		return err
	}

	if isDebug() {
		logrus.SetLevel(logrus.DebugLevel)
	}

	root := os.Args[0] + ".squashfs"
	_, err := os.Stat(root)
	if err != nil {
		return fmt.Errorf("failed to find %s: %w", root, err)
	}

	logrus.Debugf("Attaching file [%s]", root)
	dev, err := losetup.Attach(root, 0, true)
	if err != nil {
		return fmt.Errorf("creating loopback device: %w", err)
	}
	defer dev.Detach()

	if err := os.MkdirAll(usr, 0755); err != nil {
		return fmt.Errorf("failed to make dir %s: %v", usr, err)
	}

	logrus.Debugf("Mounting squashfs %s to %s", dev.Path(), usr)
	squashErr := checkSquashfs()
	err = unix.Mount(dev.Path(), usr, "squashfs", unix.MS_RDONLY, "")
	if err != nil {
		err = fmt.Errorf("mounting squashfs: %w", err)
		if squashErr != nil {
			err = fmt.Errorf("%s: %w", squashErr.Error(), err)
		}
		return err
	}

	info, err := dev.GetInfo()
	if err != nil {
		return err
	}

	info.Flags |= losetup.FlagsAutoClear
	err = dev.SetInfo(info)
	if err != nil {
		return fmt.Errorf("set loop autoclear: %w", err)
	}

	if err := os.RemoveAll("lib"); err != nil {
		return fmt.Errorf("remove lib: %w", err)
	}

	for _, p := range symlinks {
		if _, err := os.Lstat(p); os.IsNotExist(err) {
			if err := os.Symlink(filepath.Join("usr", p), p); err != nil {
				return fmt.Errorf("failed to symlink %s: %w", p, err)
			}
		}
	}

	if _, err := os.Stat("/usr/init"); err != nil {
		return fmt.Errorf("failed to find /usr/init: %w", err)
	}

	if err := umountSys(); err != nil {
		return err
	}

	err = syscall.Exec("/usr/init", os.Args, os.Environ())
	return fmt.Errorf("exec failed: %w", err)
}

func checkSquashfs() error {
	if !inProcFS() {
		insmod.Load("squashfs")
	}

	if !inProcFS() {
		return errors.New("This kernel does not support squashfs")
	}

	return nil
}

func inProcFS() bool {
	bytes, err := ioutil.ReadFile("/proc/filesystems")
	if err != nil {
		logrus.Errorf("Failed to read /proc/filesystems: %v", err)
		return false
	}
	return strings.Contains(string(bytes), "squashfs")
}
