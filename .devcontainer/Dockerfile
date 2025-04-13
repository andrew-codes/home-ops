FROM mcr.microsoft.com/devcontainers/base:bookworm
USER root
ENV OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES

RUN apt update -y --fix-missing

RUN apt-get install -y \
    apt-transport-https

RUN apt-get install -y \
    build-essential \
    ca-certificates \
    curl \
    dbus-user-session \
    dnsutils \
    etherwake \
    gettext \
    gettext-base \
    gnupg \
    gnupg2 \
    iptables \
    iputils-ping \
    libexpat1-dev \
    libssl3 \
    libssl-dev \
    locales \
    lxc \
    make \
    mosquitto-clients \
    nano \
    net-tools \
    snmp \
    software-properties-common \
    sshfs \
    sshpass \
    sudo \
    unzip \
    xsel \
    zlib1g-dev

# Telepresence
RUN curl -fL https://app.getambassador.io/download/tel2/linux/amd64/latest/telepresence -o /usr/local/bin/telepresence
RUN chmod a+x /usr/local/bin/telepresence

# FluxCD
RUN curl -s https://fluxcd.io/install.sh | FLUX_VERSION=2.0.0 bash -s ~/.local/bin

# Ansible
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
RUN locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

RUN mkdir -p ~/.kube
COPY bash_profile_setup.sh /root/.bash_profile_setup.sh
