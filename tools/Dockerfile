# Python tool image used to run the Part 2-4 scripts with pinned library versions.
FROM python:3.12-slim
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt
WORKDIR /portfolio
