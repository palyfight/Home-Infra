FROM python:3.12-alpine AS python-deps
RUN pip install --target=/python-packages pymongo

FROM n8nio/n8n:latest
COPY --from=python-deps /usr/local/bin/python3 /usr/local/bin/python3
COPY --from=python-deps /usr/local/lib/python3.12 /usr/local/lib/python3.12
COPY --from=python-deps /python-packages /usr/local/lib/python3.12/site-packages
