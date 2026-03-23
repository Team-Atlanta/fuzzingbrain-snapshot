###############################################################################
# Stage 1: Build Go binaries
###############################################################################
FROM golang:1.22 AS go-builder

WORKDIR /app

# Copy go.mod and go.sum from the crs directory
COPY crs/go.mod crs/go.sum ./
RUN go mod download

# Copy the CRS source code
COPY crs/ ./

# Build the local CRS binary
RUN CGO_ENABLED=0 GOOS=linux go build -o crs-local ./cmd/local

###############################################################################
# Stage 2: Runtime image (Debian-based for libCRS compatibility)
###############################################################################
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies including Docker
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    wget \
    tar \
    gzip \
    unzip \
    python3 \
    python3-pip \
    python3-venv \
    bash \
    jq \
    ca-certificates \
    tzdata \
    build-essential \
    openssh-client \
    openjdk-17-jdk-headless \
    rsync \
    docker.io \
    docker-buildx \
    sudo \
    llvm \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create Python virtual environment and install strategy dependencies
RUN python3 -m venv /tmp/crs_venv
RUN /bin/bash -c "source /tmp/crs_venv/bin/activate && \
    pip install --no-cache-dir \
        litellm==1.69.0 \
        tiktoken python-dotenv pyyaml openai anthropic \
        google-generativeai \
        clang==18.1.8 \
        openlit \
        loguru \
        typing-extensions"
ENV PATH="/tmp/crs_venv/bin:${PATH}"

# Set working directory
WORKDIR /app

# Copy Go binary
COPY --from=go-builder /app/crs-local /app/crs-local

# Copy VERSION file
COPY crs/VERSION /app/VERSION

# Copy Python strategy code
COPY crs/strategy /app/strategy

# Copy oss-crs scripts
COPY oss-crs/scripts /opt/fuzzing-brain-oss-crs/
RUN chmod +x /opt/fuzzing-brain-oss-crs/*

# Create directories
RUN mkdir -p /app/tasks /app/logs /crs-workdir

# Default environment
ENV GIN_MODE=release
ENV CRS_TASK_DIR=/app/tasks
ENV CRS_LOG_DIR=/app/logs
ENV STRATEGY_BASE_DIR=/app/strategy
