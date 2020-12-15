package upgrade

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/rancher/k3os/pkg/system"
	"github.com/sirupsen/logrus"
	"github.com/urfave/cli"
	"golang.org/x/sys/unix"
)

var (
	doReboot                            bool
	sourceDir, destinationDir, lockFile string
)

// Command is the `upgrade` sub-command, it performs upgrades to k3OS.
func Command() cli.Command {
	return cli.Command{
		Name:  "upgrade",
		Usage: "perform upgrades",
		Flags: []cli.Flag{
			cli.BoolFlag{
				Name:        "reboot",
				Usage:       "post-upgrade reboot?",
				EnvVar:      "K3OS_UPGRADE_REBOOT",
				Destination: &doReboot,
			},
			cli.StringFlag{
				Name:        "source",
				EnvVar:      "K3OS_UPGRADE_SOURCE",
				Value:       system.RootPath(),
				Required:    true,
				Destination: &sourceDir,
			},
			cli.StringFlag{
				Name:        "destination",
				EnvVar:      "K3OS_UPGRADE_DESTINATION",
				Value:       system.RootPath(),
				Required:    true,
				Destination: &destinationDir,
			},
			cli.StringFlag{
				Name:        "lock-file",
				EnvVar:      "K3OS_UPGRADE_LOCK_FILE",
				Value:       system.StatePath("upgrade.lock"),
				Hidden:      true,
				Destination: &lockFile,
			},
		},
		Before: func(c *cli.Context) error {
			if destinationDir == sourceDir {
				cli.ShowSubcommandHelp(c)
				logrus.Errorf("the `destination` cannot be the `source`: %s", destinationDir)
				os.Exit(1)
			}
			return nil
		},
		Action: Run,
	}
}

// Run the `upgrade` sub-command
func Run(_ *cli.Context) {
	if err := validateSystemRoot(sourceDir); err != nil {
		logrus.Fatal(err)
	}
	if err := validateSystemRoot(destinationDir); err != nil {
		logrus.Fatal(err)
	}

	// establish the lock
	lf, err := os.OpenFile(lockFile, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0644)
	if err != nil {
		logrus.Fatal(err)
	}
	defer lf.Close()
	if err = unix.Flock(int(lf.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		logrus.Fatal(err)
	}
	defer unix.Flock(int(lf.Fd()), unix.LOCK_UN)

	var atLeastOneComponentCopied bool

	if copied, err := system.CopyKernel(sourceDir, destinationDir); err != nil {
		logrus.Error(err)
	} else if copied {
		atLeastOneComponentCopied = true
	}

	if atLeastOneComponentCopied && doReboot {
		// nsenter -m -u -i -n -p -t 1 -- reboot
		if _, err := exec.LookPath("nsenter"); err != nil {
			logrus.Warn(err)
			if destinationDir != system.RootPath() {
				root := filepath.Clean(filepath.Join(destinationDir, "..", ".."))
				logrus.Debugf("attempting chroot: %v", root)
				if err := unix.Chroot(root); err != nil {
					logrus.Fatal(err)
				}
				if err := os.Chdir("/"); err != nil {
					logrus.Fatal(err)
				}
			}
		}
		cmd := exec.Command("nsenter", "-m", "-u", "-i", "-n", "-p", "-t", "1", "reboot")
		cmd.Stderr = os.Stderr
		cmd.Stdout = os.Stdout
		if err := cmd.Run(); err != nil {
			logrus.Fatal(err)
		}
	}
}

func validateSystemRoot(root string) error {
	info, err := os.Stat(root)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("stat %s: not a directory", root)
	}
	return nil
}
