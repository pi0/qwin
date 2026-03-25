FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    qemu-system-x86 qemu-utils \
    virtiofsd \
    genisoimage curl \
    && rm -rf /var/lib/apt/lists/*

COPY . /opt/winvm/
WORKDIR /opt/winvm

RUN chmod +x build.sh scripts/*.sh

# images/ is volume-mounted at runtime (ISO, disk, answer ISO)
VOLUME /opt/winvm/images

EXPOSE 3389 5985 5900 22

ENTRYPOINT ["./build.sh"]
