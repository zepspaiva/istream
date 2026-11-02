# TV service: wakes the LG TV and plays titles in Nuvio on it (see app/main.py).
FROM python:3.12-slim
RUN pip install --no-cache-dir aiowebostv==0.10.0
WORKDIR /app
COPY app/ /app/
ENV DATA_DIR=/data PORT=8080 PYTHONUNBUFFERED=1
VOLUME /data
CMD ["python", "main.py"]
