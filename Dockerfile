# syntax=docker/dockerfile:1.1.7-experimental

### BASE ###
FROM opensuse/tumbleweed as base
RUN zypper modifyrepo -k --remote
RUN zypper modifyrepo --disable repo-non-oss
RUN zypper ref
COPY overlay-sdk/usr/bin/pkg-add /usr/bin/
COPY overlay-sdk/usr/bin/gobuild /usr/bin/
COPY overlay/share/rancher/k3os/packages/sdk.list /usr/src/rootfs/usr/share/rancher/k3os/packages/
RUN --mount=type=cache,target=/var/cache/zypp/packages ROOT=/ pkg-add $(grep -v '^#' /usr/src/rootfs/usr/share/rancher/k3os/packages/sdk.list)
RUN mkdir /output
### END BASE ###


### GO BUILDS ###
ENV LINUXKIT 3f56669576bac1a44cd61f5a9fa540976d33eeed

FROM base as linuxkit
ENV GOPATH=/root/src
RUN git clone https://github.com/linuxkit/linuxkit.git $GOPATH/src/github.com/linuxkit/linuxkit
WORKDIR $GOPATH/src/github.com/linuxkit/linuxkit/pkg/metadata
RUN git checkout -b current $LINUXKIT
RUN gobuild -o /output/metadata

FROM base as kubectx
RUN git clone --branch v0.7.0 https://github.com/ahmetb/kubectx.git /usr/src/kubectx
WORKDIR /usr/src/kubectx
RUN chmod -v +x kubectx kubens
RUN cp kubectx kubens /output/

FROM base as bin
ENV GOPATH=/root/src
COPY /pkg/ $GOPATH/src/github.com/rancher/k3os/pkg/
COPY /main.go $GOPATH/src/github.com/rancher/k3os/
COPY /vendor/ $GOPATH/src/github.com/rancher/k3os/vendor/
WORKDIR $GOPATH/src/github.com/rancher/k3os
RUN gobuild -o /output/k3os
### END GO BUILDS ###

### K3S/RKE2 ###
FROM base as k3s
ARG ARCH=amd64
ENV ARCH=${ARCH}
ENV K3S_VERSION v1.19.3+k3s1
ENV RKE2_VERSION v1.18.12+rke2r1
ENV INSTALL_K3S_VERSION=${K3S_VERSION}
ENV INSTALL_K3S_SKIP_START=true
ENV INSTALL_K3S_SKIP_ENABLE=true
ENV INSTALL_K3S_BIN_DIR=/usr/bin
RUN curl -sfL https://raw.githubusercontent.com/rancher/k3s/${K3S_VERSION}/install.sh > /tmp/k3s-install.sh && \
    chmod +x /tmp/k3s-install.sh && \
    mkdir -p /run/systemd && \
    /tmp/k3s-install.sh
RUN mkdir -p /output && \
    tar cvf - /etc/systemd/system/k3s* \
              /usr/bin/k3s \
              /usr/bin/kubectl \
              /usr/bin/crictl \
              /usr/bin/ctr | tar xf - -C /output
#RUN if [ "$ARCH" = "amd64" ]; then curl -sfL https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}/rke2.linux-amd64.tar.gz | tar xvzf - -C /output/usr; fi
### END K3S ###

### SDK ###
FROM base as sdk
ARG TAG=dev
ARG VERSION=dev
ARG ARCH=amd64
ENV TAG=${TAG}
ENV ARCH=${ARCH}
COPY overlay/share/rancher/k3os/packages/ /usr/src/rootfs/usr/share/rancher/k3os/packages/
RUN --mount=type=cache,target=/var/cache/zypp/packages pkg-add $(grep -v '^#' /usr/src/rootfs/usr/share/rancher/k3os/packages/add.list)
RUN sed -i -e "s/%VERSION%/${VERSION}/g" -e "s/%ARCH%/${ARCH}/g" /usr/src/rootfs/usr/lib/os-release
COPY overlay-sdk/  /
COPY overlay/ /usr/src/rootfs/usr/
COPY install.sh /usr/src/rootfs/usr/libexec/k3os/install
COPY --from=linuxkit /output/ /usr/src/rootfs/bin
COPY --from=kubectx /output/ /usr/src/rootfs/bin
COPY --from=k3s /output/ /usr/src/rootfs/
RUN prepare-rootfs

COPY --from=bin /output/ /usr/src/rootfs/usr/sbin/
WORKDIR /output
### END SDK ###

FROM sdk as packaged
RUN package

FROM scratch as image
COPY --from=packaged /output-rootfs-extracted/ /
ENV PATH /k3os/system/k3os/current:/k3os/system/k3s/current:${PATH}

FROM base as image-stage1
ARG TAG=dev
ARG VERSION=dev
ARG ARCH=amd64
ENV TAG=${TAG}
ENV ARCH=${ARCH}
COPY --from=packaged /output/k3os-vmlinuz-${ARCH} /artifacts/vmlinuz-${VERSION}
COPY --from=packaged /output/k3os-initrd-${ARCH} /artifacts/initrd-${VERSION}
COPY --from=bin /output /artifacts
RUN cp /artifacts/* /output/ && \
    cd /output && \
    sha256sum *-${VERSION} > sha256sum

FROM scratch as image
COPY --from=image-stage1 /output/ /
ENTRYPOINT ["k3os"]
CMD ["help"]

FROM scratch as artifacts
COPY --from=packaged /output/ /
