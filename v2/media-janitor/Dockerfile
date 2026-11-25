FROM python:3.12-slim

RUN pip install --no-cache-dir requests==2.32.3

WORKDIR /app
COPY janitor.py .

ENV PYTHONUNBUFFERED=1
USER 1000:1000
ENTRYPOINT ["python", "/app/janitor.py"]
