FROM n8nio/runners:latest

USER root

# Install pymongo into the Python runner's venv
RUN VIRTUAL_ENV=/opt/runners/task-runner-python/.venv uv pip install pymongo requests

# Update the task runner config to allow pymongo and all stdlib modules
RUN sed -i 's/"N8N_RUNNERS_STDLIB_ALLOW": ""/"N8N_RUNNERS_STDLIB_ALLOW": "*"/' /etc/n8n-task-runners.json && \
    sed -i 's/"N8N_RUNNERS_EXTERNAL_ALLOW": ""/"N8N_RUNNERS_EXTERNAL_ALLOW": "pymongo,requests"/' /etc/n8n-task-runners.json

USER runner
