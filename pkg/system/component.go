package system

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/rancher/wrangler/pkg/merr"
	"github.com/sirupsen/logrus"
	"golang.org/x/sys/unix"
)

type VersionName string

const (
	sha                         = "sha256sum"
	VersionCurrent  VersionName = "current"
	VersionPrevious VersionName = "previous"
)

var (
	releaseFiles = []string{"/usr/lib/os-release", "/etc/os-release"}
)

type file struct {
	sourceName      string
	destName        string
	symlinkCurrent  string
	symlinkPrevious string
	previousDest    string
	hash            string
}

func validate(filename, hash string) error {
	f, err := os.Open(filename)
	if err != nil {
		return err
	}

	d := sha256.New()
	_, err = io.Copy(d, f)
	if err != nil {
		return err
	}

	newHash := hex.EncodeToString(d.Sum(nil))
	if hash != newHash {
		return fmt.Errorf("%s does not match expected hash %s, got %s", filename, hash, newHash)
	}

	return nil
}

func getVersion(root string) (string, error) {
	for _, releaseFile := range releaseFiles {
		f, err := os.Open(filepath.Join(root, releaseFile))
		if err != nil {
			continue
		}

		scanner := bufio.NewScanner(f)
		for scanner.Scan() {
			if strings.HasPrefix(scanner.Text(), "VERSION_ID=") {
				if err := f.Close(); err != nil {
					return "", err
				}
				return scanner.Text()[len("VERSION_ID="):], nil
			}
		}
		f.Close()
	}

	return "", fmt.Errorf("failed to find os-release in %v", releaseFiles)
}

func readFiles(src, target string) (result []file, _ error) {
	version, err := getVersion(target)
	if err != nil {
		return nil, err
	}

	f, err := os.Open(filepath.Join(src, sha))
	if err != nil {
		return nil, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) != 2 {
			continue
		}

		var (
			file       file
			hash, name = fields[0], fields[1]
		)

		for _, substring := range []string{"vmlinuz", "initrd"} {
			if strings.HasPrefix(name, substring+"-") {
				file.sourceName = filepath.Join(src, name)
				file.symlinkCurrent = filepath.Join(target, "boot", substring+"-current")
				file.symlinkPrevious = filepath.Join(target, "boot", substring+"-previous")
				file.previousDest = filepath.Join(target, "boot", substring+"-"+version)
				file.hash = hash
			}
		}

		if file.hash != "" {
			if err := validate(file.sourceName, file.hash); err != nil {
				return nil, err
			}

			result = append(result, file)
		}
	}

	if len(result) != 2 {
		return nil, fmt.Errorf("failed to find vmlinuz/initrd: %v", result)
	}

	return result, nil
}

func CopyKernel(src, root string) (bool, error) {
	files, err := readFiles(src, root)
	if err != nil {
		return false, err
	}

	var (
		setupPrevious = true
		destExists    = true
		symlinksValid = true
	)

	for _, file := range files {
		if _, err := os.Stat(file.previousDest); os.IsNotExist(err) {
			setupPrevious = false
		} else if err != nil {
			return false, err
		}
		if err := validate(file.destName, file.hash); err != nil {
			destExists = false
		}

		if target, err := filepath.EvalSymlinks(file.symlinkCurrent); err != nil || target != file.destName {
			symlinksValid = false
		}
		if setupPrevious {
			if target, err := filepath.EvalSymlinks(file.symlinkPrevious); err != nil || target != file.previousDest {
				symlinksValid = false
			}
		}
	}

	if destExists && symlinksValid {
		return false, nil
	}

	for _, file := range files {
		dest, err := os.Create(file.destName)
		if err != nil {
			return false, err
		}

		src, err := os.Open(file.sourceName)
		if err != nil {
			dest.Close()
			return false, err
		}

		logrus.Info("Copying %s => %s", file.sourceName, file.destName)
		_, err = io.Copy(dest, src)
		dest.Close()
		src.Close()
		if err != nil {
			return false, err
		}
	}

	unix.Sync()
	var errors []error

	if setupPrevious {
		for _, file := range files {
			os.Remove(file.symlinkPrevious)
			logrus.Info("Symlinking %s => %s", file.symlinkPrevious, file.previousDest)
			if err := os.Symlink(file.previousDest, file.symlinkPrevious); err != nil {
				errors = append(errors, err)
			}
		}
	}

	for _, file := range files {
		os.Remove(file.symlinkCurrent)
		logrus.Info("Symlinking %s => %s", file.symlinkCurrent, file.destName)
		if err := os.Symlink(file.destName, file.symlinkCurrent); err != nil {
			errors = append(errors, err)
		}
	}

	unix.Sync()
	return true, merr.NewErrors(errors...)
}
