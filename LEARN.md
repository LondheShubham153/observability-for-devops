# Learn Observability with Prometheus, Grafana and OpenTelemetry

A short, hands-on path. Everything here was run against this repo on a clean start (`docker compose down -v` then `up`).

## 1. Concepts

### Monitoring vs observability

**Monitoring** means you decide ahead of time what to watch (CPU, error rate, disk) and get alerted when a known number crosses a line. It answers "is something broken?".

**Observability** means your system emits enough detailed data that you can ask *new* questions after the fact, such as "why was this one request slow?", without shipping new code. Monitoring is something you do with that data, and observability is what makes it possible. You need both: alerts to tell you something is wrong, and rich data to find out why.

### The three signals

Observability rests on three kinds of data, called **signals**:

| Signal | Answers | Stored in | Query language |
|--------|---------|-----------|----------------|
| **Metrics** | How much? How fast? (numbers over time) | Prometheus | PromQL |
| **Logs** | What happened? (text events) | Loki | LogQL |
| **Traces** | Where did this one request spend its time? | Tempo | TraceQL |

### What is OpenTelemetry?

Before OpenTelemetry (OTel), every tool had its own libraries, agents and data formats. Switching from one backend to another meant re-instrumenting your code. OTel is an open, vendor-neutral standard that fixes this: **instrument once, send anywhere**. It has three parts:

- **API and SDK**: the libraries your app uses to create telemetry (available for most languages: Python, Java, Go, JavaScript, .NET and more).
- **OTLP**: the protocol telemetry travels in.
- **Collector**: a small service that receives telemetry and routes each signal to the right backend.

OTel does not store or display anything. It produces and moves the data. Prometheus, Loki and Tempo store it, and Grafana shows it.

```
Notes App ──OTLP──► Collector ──► Prometheus (metrics)
                        ├───────► Tempo      (traces)
                        └───────► Loki       (logs)
Node Exporter, cAdvisor ──scraped──► Prometheus
                                   Grafana reads all three
```

Why a Collector? You can swap a backend (say Tempo for Jaeger) by editing one config file. The app never changes.

### What is instrumentation?

Instrumentation is the code that makes an app emit telemetry. There are two kinds:

- **Automatic**: an agent wraps the libraries you already use (the web framework, the database driver). No code changes. The notes app works this way (section 8).
- **Manual**: you add your own spans, metrics and logs for your business logic (section 9).

### The four Prometheus metric types

Every metric in Prometheus has one of four types. The type tells you how to query it.

| Type | What it is | Example in this stack | How to use it |
|------|-----------|----------------------|---------------|
| **Counter** | Only goes up (resets on restart) | `node_cpu_seconds_total` | Wrap in `rate()`: `rate(node_cpu_seconds_total{mode="user"}[1m])` |
| **Gauge** | Goes up and down | `node_memory_MemAvailable_bytes`, `http_server_active_requests` | Read it directly: `node_memory_MemAvailable_bytes` |
| **Histogram** | Counts observations into buckets (`_bucket`, plus `_count` and `_sum`) | `http_server_duration_milliseconds_bucket` | `histogram_quantile(0.95, ...)` for a percentile (section 3) |
| **Summary** | Like a histogram, but the percentiles are computed inside the app | `go_gc_duration_seconds` (Prometheus' own garbage-collection time) | Read the `quantile` label: `go_gc_duration_seconds{job="prometheus"}` |

A good rule of thumb: counters answer "how many?", gauges answer "how much right now?", and histograms answer "how long?". Prefer histograms over summaries, because histograms can be added up across several instances and summaries can't.

## 2. Start it

```bash
docker compose up -d --build
```

Open Grafana at http://localhost:3000 (admin / admin). Then make some traffic. This creates notes, lists them, and hits a bad URL so there are errors to find:

```bash
./scripts/traffic.sh          # 60 seconds of mixed traffic
```

You can also create notes by hand at http://localhost:8000.

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
3. Click the `GET api/notes/` row to open its details, then click **Logs for this trace**. Grafana opens the logs from that exact request in Loki: `listed N notes`.

How it works: a log written while a request is being handled is stamped with that request's `trace_id`, and Grafana's Tempo datasource is told which Loki query to run (`grafana/provisioning/datasources/datasources.yml`). A metric tells you something is wrong, a trace shows where, and the log shows why.

The log line comes from one line in `notes-app/api/views.py` (`logger.info("listed %d notes", ...)`). Only logs written inside a request get a trace ID, so traces for requests that log nothing have no logs to jump to. Also, Python's root logger defaults to WARNING, so an INFO log is dropped unless its logger is set to INFO (`logger.setLevel(logging.INFO)`).

## 7. Alerting

Dashboards need someone looking at them. **Alerts** tell you when something is wrong.

- **Prometheus** evaluates the rules in `prometheus/alerts.yml` every 15 seconds. An alert is **inactive**, then **pending** (the condition is true, but not for long enough yet), then **firing** (it has held for the whole `for:` time).
- **Alertmanager** receives firing alerts, groups them and decides who to notify (`alertmanager/alertmanager.yml`). Here it has no notification target, so alerts are simply visible in its UI. The file has a comment showing where Slack or email would go.

There are two rules. Look at their conditions in `prometheus/alerts.yml`, then trigger each one on purpose.

**1. `HighErrorRate`: more than half of the app's requests are failing.**

```bash
./scripts/traffic.sh errors 150
```

Watch http://localhost:9090/alerts. After about 45 seconds the alert is **pending**, and within about two minutes it is **firing**. It then appears in Alertmanager at http://localhost:9093. The **Firing alerts** tile on the *Start Here* dashboard turns to 1. To resolve it, send healthy traffic:

```bash
./scripts/traffic.sh normal 120
```

**2. `TargetDown`: a scrape target stopped responding.**

```bash
docker stop node-exporter
```

Within about a minute `TargetDown` fires for `node-exporter`. Bring it back and watch the alert clear:

```bash
docker start node-exporter
```

Challenge: add your own rule to `prometheus/alerts.yml`, for example "p95 latency above 100 ms" using the histogram query from section 3. Then run `docker compose restart prometheus` and check it shows up under http://localhost:9090/alerts.

## 8. How the pipeline is wired

Three small files do all the work:

- **`notes-app/Dockerfile`**: `opentelemetry-instrument` wraps the Django app. Zero code changes give you traces for requests and DB queries, request metrics, and log forwarding.
- **`docker-compose.yml` (notes-app `environment`)**: tells the app where the Collector is (`OTEL_EXPORTER_OTLP_ENDPOINT`) and what to call itself (`OTEL_SERVICE_NAME`).
- **`otel-collector/otel-collector-config.yml`**: `receivers` (take OTLP in) → `processors` (batch) → `exporters` (one per backend). Each signal has its own pipeline under `service.pipelines`.

## 9. Add your own telemetry

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

## 10. Troubleshooting

| Symptom | Cause and fix |
|---------|---------------|
| App metrics panels are empty | `rate()` needs recent traffic. Send requests and wait about 30s. |
| `notes-app` crash-loops with `ALLOWED_HOSTS` error | `DJANGO_SETTINGS_MODULE` must be set in the environment (already in the compose file). |
| `container_*{name="..."}` returns nothing | On Docker Desktop, cAdvisor labels containers by `id` only. Use `{id=~"/docker/.+"}`. |
| "Logs for this trace" shows "No logs found" | That request wrote no log inside the request. Open a `GET api/notes/` trace. In your own code, make sure the logger level is INFO (see section 6). |
| A trace ID from Tempo search finds no logs | Tempo drops leading zeros. Trace IDs are 32 hex characters, so left-pad with `0`. The "Logs for this trace" button does this for you. |
| `HighErrorRate` never fires | It needs more than 0.1 requests/s and more than 50% failures for a full minute. Use `./scripts/traffic.sh errors 150` and wait about two minutes. |
| Alertmanager at `:9093` shows no alerts | Normal when nothing is firing. Trigger one with the steps in section 7. |
| Port 5000 already in use (your own Flask apps) | macOS AirPlay Receiver uses it. Pick another port. |
| Datasource or dashboard errors after pulling changes | Old data volume. Run `docker compose down -v` and start again. |
| A counter named `orders_total` shows up as `orders_total` | Prometheus only adds `_total` if it's missing. |

## 11. Where to go next

- Send alerts somewhere real: add a Slack or email receiver to `alertmanager/alertmanager.yml`.
- Run the same ideas on Kubernetes, using Helm charts for each component.
- Instrument a service in another language. Only the SDK changes, the Collector config stays the same.
- Swap a backend (for example Jaeger for Tempo) by editing only the Collector exporters.
