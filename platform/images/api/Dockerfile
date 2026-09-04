FROM registry.threadforge.local:30500/mirror/docker.io/library/python:3.12-slim-bookworm

WORKDIR /app

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# Copy runtime package
COPY runtime/ /app/runtime/
COPY requirements/ /app/requirements/
COPY pyproject.toml /app/
COPY README.md /app/

# Install Python dependencies
RUN pip install --no-cache-dir -r /app/requirements/runtime.txt
RUN pip install --no-cache-dir -e .

# Create logs directory
RUN mkdir -p /app/logs && \
    chmod 777 /app/logs

# Non-root user
RUN useradd -m -u 1000 threadforge && \
    chown -R threadforge:threadforge /app

USER threadforge

# Expose metrics and API ports
EXPOSE 8080 9090

# Run FastAPI application
CMD ["uvicorn", "runtime.api.app:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers"]
