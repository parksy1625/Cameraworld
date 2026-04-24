# Base CUDA image for GPU reconstruction. On a CPU-only host swap in
# python:3.11-slim — COLMAP/3DGS steps will fail, but the orchestrator
# structure can still be smoke-tested.
FROM nvidia/cuda:12.1.1-cudnn8-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3.11 python3-pip python3.11-dev \
        ffmpeg colmap \
        git curl build-essential \
        libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

RUN ln -sf /usr/bin/python3.11 /usr/bin/python

WORKDIR /app

COPY pipeline/pyproject.toml /app/
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir .

# Pull the official 3D Gaussian Splatting reference implementation.
# The training step is invoked via subprocess in stages/gaussian_splat.py.
RUN git clone --depth=1 --recursive \
        https://github.com/graphdeco-inria/gaussian-splatting.git \
        /opt/gaussian-splatting || true

COPY pipeline /app

CMD ["python", "-m", "cameraworld_pipeline.worker"]
