FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir -U pip

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh

RUN mkdir -p /app/data

ENV PYTHONUNBUFFERED=1

EXPOSE 8790

ENTRYPOINT ["/app/docker-entrypoint.sh"]
