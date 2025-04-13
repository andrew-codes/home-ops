#!/usr/bin/env bash
set -e

/usr/local/share/docker-init.sh

corepack enable
corepack use yarn
yarn dlx @yarnpkg/sdks vscode

pip3 install "pywinrm>=0.3.0"
pip3 install "PyYAML"
ansible-galaxy collection install ansible.windows
ansible-galaxy collection install community.windows
ansible-galaxy collection install kubernetes.core

git config --global --add safe.directory /workspaces/home-ops

# Add .bash_profile_setup.sh to .bash_profile only if not already sourced
if ! grep -q "source /root/.bash_profile_setup.sh" /root/.bash_profile; then
    echo "source /root/.bash_profile_setup.sh" >>/root/.bash_profile
fi

# Add .bash_profile_setup.sh to .bashrc only if not already sourced
# curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
# chmod +x kubectl
# mv ./kubectl /usr/bin/kubectl
