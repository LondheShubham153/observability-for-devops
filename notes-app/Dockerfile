FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt /app
RUN pip install -r requirements.txt
# Install the OpenTelemetry instrumentation matching the libraries above (Django, etc.)
RUN opentelemetry-bootstrap -a install

COPY . /app

EXPOSE 8000

# opentelemetry-instrument wraps the app: traces, metrics and logs with zero code changes
CMD python manage.py migrate && \
    opentelemetry-instrument python manage.py runserver 0.0.0.0:8000 --noreload
