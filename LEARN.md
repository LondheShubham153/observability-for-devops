# Learn Observability with Prometheus, Grafana and OpenTelemetry

A short, hands-on path. Everything here was run against this repo on a clean start (`docker compose down -v` then `up`).

## 1. The idea in one minute

Observability means you can answer "what is my system doing and why?" from the outside. It rests on three kinds of data, called **signals**:

| Signal | Answers | Stored in | Query language |
|--------|---------|-----------|----------------|
| **Metrics** | How much? How fast? (numbers over time) | Prometheus | PromQL |
| **Logs** | What happened? (text events) | Loki | LogQL |
| **Traces** | Where did this one request spend its time? | Tempo | TraceQL |

**OpenTelemetry (OTel)** is the vendor-neutral standard for producing all three. The app speaks one protocol (OTLP) to one place (the **Collector**), and the Collector decides where each signal goes. Grafana is the single window onto all three.

```
Notes App ──OTLP──► Collector ──► Prometheus (metrics)
                        ├───────► Tempo      (traces)
                        └───────► Loki       (logs)
Node Exporter, cAdvisor ──scraped──► Prometheus
                                   Grafana reads all three
```

Why a Collector? You can swap a backend (say Tempo for Jaeger) by editing one config file. The app never changes.

## 2. Start it

```bash
docker compose up -d --build
```

Open Grafana at http://localhost:3000 (admin / admin). Then make some traffic. Create notes at http://localhost:8000, and also hit a bad URL so there are errors to find:

```bash
for i in $(seq 1 30); do
  curl -s -o /dev/null localhost:8000/api/notes/
  curl -s -o /dev/null localhost:8000/nope      # a 404
done
```

Wait about 30 seconds. App metrics are exported every 15s, then scraped every 15s.

Grafana opens on the **Start Here** dashboard. It links to a dashboard for each component (app, traces, logs, Collector, Prometheus, Grafana, host and containers). Have a look around before running queries yourself.

## 3. Metrics with PromQL

In Grafana: **Explore → Prometheus**. Run these in order.

```promql
up
```
Which targets Prometheus scrapes, `1` = healthy. Same list as http://localhost:9090/targets.

```promql
sum(rate(http_server_duration_milliseconds_count{exported_job="notes-app"}[1m]))
```
Requests per second. Read it inside out: `_count` is a counter that only goes up, `rate(...[1m])` turns it into "per second over the last minute", and `sum` adds up all label combinations.

```promql
sum by (http_status_code) (rate(http_server_duration_milliseconds_count{exported_job="notes-app"}[1m]))
```
Same thing split by status code. You should see 200 and 404 lines.

```promql
histogram_quantile(0.95, sum by (le) (rate(http_server_duration_milliseconds_bucket{exported_job="notes-app"}[1m])))
```
p95 latency in ms: 95% of requests were faster than this. Latency is stored as a histogram (`_bucket`), and `histogram_quantile` reads a percentile out of it.

```promql
100 - avg(rate(node_cpu_seconds_total{mode="idle"}[1m])) * 100
```
Host CPU % (from Node Exporter).

```promql
topk(3, container_memory_usage_bytes{id=~"/docker/.+"})
```
Top 3 containers by memory (from cAdvisor).

The **Notes App (RED)** dashboard is these queries on a screen. The **OpenTelemetry Collector** dashboard shows the pipeline itself: what goes in, what is sent to each backend, and anything refused. RED = **R**ate, **E**rrors, **D**uration, the three numbers to check first for any service.

## 4. Logs with LogQL

**Explore → Loki**.

```logql
{service_name="notes-app"}
```
All logs for the app. `{...}` is the label selector, which picks the streams.

```logql
{service_name="notes-app"} |= "Not Found"
```
`|=` keeps lines containing the text. You'll see the 404s you caused.

```logql
{service_name="notes-app"} | detected_level="warn"
```
`detected_level` is metadata Loki extracts from the log record, so filter on it after the `|`, not inside `{}`.

```logql
sum(count_over_time({service_name="notes-app"}[1m]))
```
Turn logs into a number: log lines per minute.

## 5. Traces with TraceQL

**Explore → Tempo → TraceQL**.

```traceql
{ resource.service.name = "notes-app" }
```
Every trace from the app. Open one. A trace is a tree of **spans**: one for the HTTP request, with child spans for things like the database `SELECT`. Each span has a start time and a duration, so you can see where time went.

```traceql
{ duration > 50ms }
```
Only slow traces.

## 6. The payoff: jump between signals

1. Load the notes list in the app (or `curl localhost:8000/api/notes/`) so the request writes a log line.
2. In **Explore → Tempo**, run `{ name = "GET api/notes/" }` and open a trace.
3. Click **Logs for this span**. Grafana opens the logs from that exact request in Loki: `listed N notes`.

How it works: a log written while a request is being handled is stamped with that request's `trace_id`, and Grafana's Tempo datasource is told which Loki query to run (`grafana/provisioning/datasources/datasources.yml`). A metric tells you something is wrong, a trace shows where, and the log shows why.

The log line comes from one line in `notes-app/api/views.py` (`logger.info("listed %d notes", ...)`). Only logs written inside a request get a trace ID, so traces for requests that log nothing have no logs to jump to. Also, Python's root logger defaults to WARNING, so an INFO log is dropped unless its logger is set to INFO (`logger.setLevel(logging.INFO)`).

## 7. How the pipeline is wired

Three small files do all the work:

- **`notes-app/Dockerfile`**: `opentelemetry-instrument` wraps the Django app. Zero code changes give you traces for requests and DB queries, request metrics, and log forwarding.
- **`docker-compose.yml` (notes-app `environment`)**: tells the app where the Collector is (`OTEL_EXPORTER_OTLP_ENDPOINT`) and what to call itself (`OTEL_SERVICE_NAME`).
- **`otel-collector/otel-collector-config.yml`**: `receivers` (take OTLP in) → `processors` (batch) → `exporters` (one per backend). Each signal has its own pipeline under `service.pipelines`.

## 8. Add your own telemetry

Auto-instrumentation covers the framework. For your own business logic, use the OTel API. This runs under the same `opentelemetry-instrument` wrapper (tested in a standalone Flask app):

```python
import logging
from opentelemetry import trace, metrics

tracer = trace.get_tracer("my-app")
orders = metrics.get_meter("my-app").create_counter("orders_total")
log = logging.getLogger("my-app")

def place_order(amount):
    with tracer.start_as_current_span("process-order") as span:   # your own span
        span.set_attribute("order.amount", amount)                # searchable in TraceQL
        orders.add(1, {"kind": "web"})                            # your own metric
        log.info("order placed amount=%s", amount)                # carries the trace_id
```

Then try:

```traceql
{ resource.service.name = "my-app" && name = "process-order" && span.order.amount > 50 }
```
```promql
orders_total
```

Challenge: put this in `notes-app/api/views.py`, rebuild with `docker compose up -d --build notes-app`, and chart your counter in Grafana.

## 9. Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| App metrics panels are empty | `rate()` needs recent traffic. Send requests and wait about 30s. |
| `notes-app` crash-loops with `ALLOWED_HOSTS` error | `DJANGO_SETTINGS_MODULE` must be set in the environment (already in the compose file). |
| `container_*{name="..."}` returns nothing | On Docker Desktop, cAdvisor labels containers by `id` only. Use `{id=~"/docker/.+"}`. |
| "Logs for this span" shows nothing | That request wrote no log inside the request. Open a `GET api/notes/` trace. In your own code, make sure the logger level is INFO (see section 6). |
| A trace ID from Tempo search finds no logs | Tempo drops leading zeros. Trace IDs are 32 hex characters, so left-pad with `0`. The "Logs for this span" button does this for you. |
| Port 5000 already in use (your own Flask apps) | macOS AirPlay Receiver uses it. Pick another port. |
| Datasource or dashboard errors after pulling changes | Old data volume. Run `docker compose down -v` and start again. |
| A counter named `orders_total` shows up as `orders_total` | Prometheus only adds `_total` if it's missing. |

## 10. Where to go next

- Alerting: Prometheus rules plus Alertmanager.
- Instrument a service in another language. Only the SDK changes, the Collector config stays the same.
- Swap a backend (for example Jaeger for Tempo) by editing only the Collector exporters.
