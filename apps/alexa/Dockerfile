FROM nvidia/cuda:12.5.0-runtime-ubuntu22.04

# Install Whisper
WORKDIR /usr/src
ARG WHISPER_VERSION='3.0.2'

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential \
      python3 \
      python3-dev \
      python3-pip && \
    rm -rf /var/lib/apt/lists/*

# Upgrade pip tooling
RUN python3 -m pip install --no-cache-dir -U pip setuptools wheel

# Install wyoming-faster-whisper and CUDA 12 runtime libs via pip
RUN python3 -m pip install --no-cache-dir \
      "wyoming-faster-whisper==${WHISPER_VERSION}" \
      nvidia-cublas-cu12 \
      nvidia-cudnn-cu12

# Register pip-provided NVIDIA lib dirs with ldconfig so cudnn/cublas are resolvable
RUN python3 - << 'PY'
import site, os
paths=[]
for p in site.getsitepackages():
  for sub in ('nvidia/cublas/lib','nvidia/cudnn/lib'):
    d=os.path.join(p, sub)
    if os.path.isdir(d):
      paths.append(d)
open('/etc/ld.so.conf.d/nvidia-python.conf','w').write('\n'.join(paths)+'\n')
PY
RUN ldconfig

WORKDIR /
COPY src/run.sh ./

ENTRYPOINT ["bash", "/run.sh"]
