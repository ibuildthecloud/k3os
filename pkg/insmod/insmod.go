package insmod

import (
	"bytes"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"
	"strings"

	"github.com/ulikunitz/xz"
	"golang.org/x/sys/unix"
)

func getModuleRoot() (string, error) {
	uname := unix.Utsname{}
	if err := unix.Uname(&uname); err != nil {
		return "", err
	}

	return filepath.Join(
		"/lib/modules",
		string(uname.Release[:bytes.IndexByte(uname.Release[:], 0)]),
	), nil
}

func Load(filename string) error {
	root, err := getModuleRoot()
	if err != nil {
		return err
	}

	return filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if info.IsDir() {
			return nil
		}

		i := strings.Index(info.Name(), ".")
		if i <= 0 {
			return nil
		}
		if filename == info.Name()[:i] {
			data, err := open(path)
			if err != nil {
				return fmt.Errorf("failed to open %s: %w", path, err)
			}
			if err := unix.InitModule(data, ""); err != nil {
				return fmt.Errorf("failed to load module %s: %w", path, err)
			}
		}

		return nil
	})
}

func open(path string) ([]byte, error) {
	data, err := ioutil.ReadFile(path)
	if err != nil {
		return nil, err
	}

	if strings.HasSuffix(path, ".xz") {
		r, err := xz.NewReader(bytes.NewBuffer(data))
		if err != nil {
			return nil, err
		}
		return ioutil.ReadAll(r)
	}

	return data, nil
}
