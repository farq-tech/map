# Farq map tiles: builds the archive (build.sh → build_tiles.py) and serves it (serve.py) from one container.
# Mount a persistent volume at /data. The DuckDB spatial extension is installed at image build time so a rebuild
# never depends on reaching the extension repository.
FROM python:3.13-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && python3 -c "import duckdb; duckdb.connect().execute('INSTALL spatial')"
COPY build_tiles.py serve.py build.sh fetch_atlas.py ./
ENV TILES_DATA_DIR=/data PORT=8080 REBUILD_HOURS=168 BUILD_ON_START=1 TILES_MEMORY_LIMIT=6GB
EXPOSE 8080
CMD ["python3", "serve.py"]
