.dapper:
	@echo Downloading dapper
	@curl -sL https://releases.rancher.com/dapper/latest/dapper-`uname -s`-`uname -m` > .dapper.tmp
	@@chmod +x .dapper.tmp
	@./.dapper.tmp -v
	@mv .dapper.tmp .dapper

image: sdk
	./scripts/docker-build image

sdk:
	./scripts/docker-build sdk

run-sdk: sdk
	./scripts/docker-run sdk

run-live: artifacts
	./scripts/run-qemu k3os.mode=live k3os.debug

run: artifacts
	./scripts/run-qemu k3os.debug

rescue: artifacts
	./scripts/run-qemu k3os.debug rescue

artifacts: sdk
	./scripts/docker-build artifacts -o ./dist/artifacts/

dist: artifacts image sdk

.DEFAULT_GOAL := artifacts

.PHONY: $(TARGETS)
