FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    qemu-system-x86 qemu-utils \
    virtiofsd \
    genisoimage curl openssh-client \
    novnc websockify \
    && rm -rf /var/lib/apt/lists/*

COPY . /opt/winvm/
WORKDIR /opt/winvm

RUN chmod +x run.sh build.sh scripts/*.sh \
    && ln -sf vnc.html /usr/share/novnc/index.html

# images/ is volume-mounted at runtime (ISO, disk, answer ISO)
VOLUME /opt/winvm/images

EXPOSE 3389 5900 6080 22

ENTRYPOINT ["bash", "scripts/build.sh"]
