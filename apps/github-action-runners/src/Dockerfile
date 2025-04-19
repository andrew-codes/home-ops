FROM summerwind/actions-runner:ubuntu-22.04
ENV DEBIAN_FRONTEND=noninteractive
ENV OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
USER root
RUN apt update -y
RUN apt-get install -y \
  curl \
  gettext \
  gnupg2 \
  gpg \
  libcurl4-gnutls-dev \
  libexpat1-dev \
  libghc-zlib-dev \
  libssl-dev \
  make \
  software-properties-common \
  unzip

# kubectl
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
RUN echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | tee -a /etc/apt/sources.list.d/kubernetes.list

# Ansible
RUN echo "deb http://ppa.launchpad.net/ansible/ansible/ubuntu focal main"
RUN add-apt-repository -y --update ppa:ansible/ansible
RUN add-apt-repository -y --update ppa:deadsnakes/ppa

RUN apt update -y --fix-missing
RUN apt-get upgrade -y
RUN apt-get install -y \
  ansible \
  ansible-lint \
  bash \
  ca-certificates \
  dbus-user-session \
  etherwake \
  gettext-base \
  gnupg2 \
  iptables \
  jq \
  kubectl \
  libssl3 \
  locales \
  lxc \
  python-apt-common \
  python3-apt \
  python3-pip \
  python3.11 \
  sshpass

RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/library-scripts

# Ansible
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
RUN locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8
RUN pip3 install "pywinrm>=0.3.0"
RUN pip3 install "PyYAML"
RUN ansible-galaxy collection install ansible.windows
RUN ansible-galaxy collection install community.windows
RUN ansible-galaxy collection install kubernetes.core

# kubctl
RUN export KUBECONFIG=/home/runner/.kube/config

# yq
RUN curl https://github.com/mikefarah/yq/releases/download/v4.6.3/yq_linux_amd64 -o /usr/local/bin/yq
RUN chmod +x /usr/local/bin/yq

# helm
RUN curl -fsSL -o helm.tar.gz https://get.helm.sh/helm-v3.6.1-linux-amd64.tar.gz
RUN tar -zxvf helm.tar.gz
RUN mv linux-amd64/helm /usr/local/bin/helm
RUN chmod +x /usr/local/bin/helm

# go, jsonnet
RUN curl -s https://dl.google.com/go/go1.18.1.linux-amd64.tar.gz | tar -xz -C /usr/local
RUN ln -s /usr/local/go/bin/go /usr/local/bin

# codecov
RUN curl -Os https://uploader.codecov.io/latest/linux/codecov
RUN chmod +x codecov
RUN ln -s codecov /usr/local/bin

# git
RUN git clone https://github.com/git/git.git
RUN cd git && git checkout v2.38.1 && make prefix=/usr/local all && make prefix=/usr/local install

# rover
RUN curl -sSL https://rover.apollo.dev/nix/latest | sh

RUN mkdir -p /home/runner/.cache/node/corepack
RUN chown --recursive runner /home/runner

USER runner
