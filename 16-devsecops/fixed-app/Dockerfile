# Current slim base: 44 HIGH/CRITICAL CVEs vs 2265 on python:3.9
FROM python:3.13-slim

# DS-0002 fixed: run as a non-root user
RUN useradd --create-home --shell /bin/bash appuser
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 5000
CMD ["python", "app.py"]
