# Writer & Critic as a container, for Google Cloud Run. Build from this folder:
#   gcloud run deploy writer-critic --source . ...   (see README.md)
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# The Eval Workbench SDK, installed from the Workbench that will receive the traces (it hosts the wheel at /sdk/).
ARG WORKBENCH_URL=https://eval-workbench-5lofnwh6hq-uc.a.run.app
ARG SDK_VERSION=0.2.0
RUN pip install --no-cache-dir "${WORKBENCH_URL}/sdk/eval_workbench-${SDK_VERSION}-py3-none-any.whl"

COPY app.py cli.py ./
COPY writer_critic ./writer_critic
COPY static ./static
ENV PYTHONUNBUFFERED=1

# Set OPENAI_API_KEY (or ANTHROPIC_API_KEY) from Secret Manager, and EVAL_WORKBENCH_URL, EVAL_WORKBENCH_API_KEY and
# APP_VERSION to send each run to the Workbench.
CMD ["sh", "-c", "uvicorn app:app --host 0.0.0.0 --port ${PORT:-8080}"]
