FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1 OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
WORKDIR /code
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app app
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
