# Official Python image (Debian "slim" variant), pulled from the Amazon ECR Public mirror of
# Docker Hub's library images so CodeBuild is not hit by Docker Hub's anonymous pull rate limit.
FROM public.ecr.aws/docker/library/python:3.11-slim-bookworm

# PYTHONUNBUFFERED: flush stdout/stderr immediately so logs reach CloudWatch in real time.
# PYTHONDONTWRITEBYTECODE / PIP_NO_CACHE_DIR: keep .pyc files and pip's cache out of the image.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore \
    APP_PORT=5153

WORKDIR /app

# Install dependencies before copying the source so this layer stays cached until
# requirements.txt changes. psycopg2-binary ships a prebuilt wheel with libpq bundled,
# so no compiler or libpq-dev system packages are needed.
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

# Run as an unprivileged user instead of root.
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 5153

CMD ["python", "app.py"]
