# Start from an existing Linux image containing Python 3.12.
# 'slim' means it contains fewer operating-system utilities to reduce size.
FROM python:3.12-slim
# UNBUFFERED: print Python logs immediately; DONTWRITEBYTECODE: skip .pyc caches.
# PIP_NO_CACHE_DIR: do not retain pip's download cache in the image.
# OMP/OPENBLAS: numerical libraries use one thread for this tiny model.
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
# Following commands and relative container paths start from /code.
WORKDIR /code
# Copy dependency definitions first, allowing Docker to cache their installation.
COPY requirements.txt .
# RUN executes during IMAGE BUILD, installing dependencies into the image.
RUN pip install -r requirements.txt
# Copy this project's app/ folder into /code/app inside the image.
COPY app app
# CMD runs at CONTAINER START, not during the build.
# uvicorn is the HTTP server. app.main:app means the app object in app/main.py.
# --host 0.0.0.0 listens on container network interfaces; --port 8000 selects its port.
# Compose/Kubernetes replace CMD for the worker, MLflow, and training processes.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
