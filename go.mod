module github.com/rancher/k3os

go 1.13

require (
	github.com/docker/docker v1.13.1
	github.com/ghodss/yaml v1.0.0
	github.com/konsorten/go-windows-terminal-sequences v1.0.2 // indirect
	github.com/mattn/go-isatty v0.0.10
	github.com/pkg/errors v0.9.1
	github.com/rancher/mapper v0.0.0-20190814232720-058a8b7feb99
	github.com/rancher/wrangler v0.7.2
	github.com/sirupsen/logrus v1.4.2
	github.com/ulikunitz/xz v0.5.8
	github.com/urfave/cli v1.22.2
	golang.org/x/crypto v0.0.0-20200622213623-75b288015ac9
	golang.org/x/sys v0.0.0-20200930185726-fdedc70b468f
	gopkg.in/freddierice/go-losetup.v1 v1.0.0-20170407175016-fc9adea44124
)

replace k8s.io/client-go => k8s.io/client-go v0.19.0
