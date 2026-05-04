#!/usr/bin/env bash
# =============================================================================
# setup_raft_metrics.sh
# Uses your existing fork at /Users/salemalqahtani/Desktop/RAFT/raft
# Demo app goes into /Users/salemalqahtani/Desktop/RAFT/metrics-demo
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

FORK_DIR="/Users/salemalqahtani/Desktop/RAFT/raft"
DEMO_DIR="/Users/salemalqahtani/Desktop/RAFT/metrics-demo"

# =============================================================================
# 1. CHECK GO
# =============================================================================
info "Checking Go installation..."
if ! command -v go &>/dev/null; then
  error "Go not found. Install from https://go.dev/dl/ (need 1.24+)"
fi
GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
REQUIRED="1.22"
if [[ "$(printf '%s\n' "$REQUIRED" "$GO_VERSION" | sort -V | head -1)" != "$REQUIRED" ]]; then
  error "Go $GO_VERSION found, need $REQUIRED+. Upgrade at https://go.dev/dl/"
fi
info "Go $GO_VERSION ✓"

# =============================================================================
# 2. CHECK YOUR FORK EXISTS
# =============================================================================
if [ ! -d "$FORK_DIR" ]; then
  error "Fork not found at $FORK_DIR"
fi
info "Fork found at $FORK_DIR ✓"

# =============================================================================
# 3. INIT go.mod IN FORK IF MISSING
# =============================================================================
cd "$FORK_DIR"
if [ ! -f "go.mod" ]; then
  warn "go.mod not found — initializing module..."
  go mod init github.com/hashicorp/raft
  go mod tidy
  info "go.mod created ✓"
else
  info "go.mod found ✓"
fi

# =============================================================================
# 4. QUICK TEST ON YOUR FORK
# =============================================================================
info "Running TestRaft_SingleNode against your fork..."
go test -tags hashicorpmetrics -run TestRaft_SingleNode -v -timeout 60s
info "Fork tests passed ✓"

# =============================================================================
# 5. CREATE DEMO APP
# =============================================================================
info "Setting up demo app at $DEMO_DIR..."
mkdir -p "$DEMO_DIR"
cd "$DEMO_DIR"

if [ ! -f "go.mod" ]; then
  go mod init raft-metrics-demo
  info "Demo go.mod created ✓"
else
  warn "Demo go.mod already exists — skipping init ✓"
fi

go mod edit -replace github.com/hashicorp/raft="$FORK_DIR"
info "go.mod replace → github.com/hashicorp/raft => $FORK_DIR ✓"

# =============================================================================
# 6. WRITE DEMO APP WITH BUILT-IN DASHBOARD
# =============================================================================
cat > main.go << 'GOEOF'
package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/hashicorp/go-hclog"
	gometrics "github.com/hashicorp/go-metrics"
	prometheussink "github.com/hashicorp/go-metrics/prometheus"
	"github.com/hashicorp/raft"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type fsmSnapshot struct{}
func (s *fsmSnapshot) Persist(sink raft.SnapshotSink) error { return sink.Close() }
func (s *fsmSnapshot) Release()                              {}

type simpleFSM struct{}
func (f *simpleFSM) Apply(l *raft.Log) interface{}       { return nil }
func (f *simpleFSM) Snapshot() (raft.FSMSnapshot, error) { return &fsmSnapshot{}, nil }
func (f *simpleFSM) Restore(rc io.ReadCloser) error      { return rc.Close() }

var globalRaft *raft.Raft

const dashboardHTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta http-equiv="refresh" content="3">
<title>Raft Metrics Dashboard</title>
<style>
* { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; }
body { background: #f5f5f5; padding: 24px; color: #1a1a1a; }
h1 { font-size: 20px; font-weight: 600; margin-bottom: 4px; }
.subtitle { font-size: 13px; color: #666; margin-bottom: 24px; }
.section { font-size: 11px; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: #999; margin-bottom: 12px; margin-top: 24px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; margin-bottom: 8px; }
.card { background: #fff; border-radius: 10px; padding: 16px; border: 1px solid #e8e8e8; }
.card-label { font-size: 12px; color: #888; margin-bottom: 6px; }
.card-value { font-size: 26px; font-weight: 600; }
.card-unit { font-size: 13px; color: #888; margin-left: 2px; font-weight: 400; }
.card-sub { font-size: 12px; color: #aaa; margin-top: 4px; }
.green { color: #2d7a3a; }
.amber { color: #b06000; }
.red { color: #b02020; }
.blue { color: #1a5fa8; }
.pill { display: inline-block; font-size: 11px; padding: 2px 8px; border-radius: 20px; font-weight: 500; margin-top: 6px; }
.pill-green { background: #e6f4ea; color: #2d7a3a; }
.pill-amber { background: #fef3e2; color: #b06000; }
.pill-red { background: #fdecea; color: #b02020; }
.row-card { background: #fff; border-radius: 10px; padding: 14px 16px; border: 1px solid #e8e8e8; margin-bottom: 8px; display: flex; align-items: center; gap: 16px; }
.row-name { font-size: 13px; color: #555; width: 220px; flex-shrink: 0; }
.bar-wrap { flex: 1; height: 8px; background: #f0f0f0; border-radius: 4px; overflow: hidden; }
.bar { height: 100%; border-radius: 4px; }
.row-val { font-size: 13px; font-weight: 600; width: 90px; text-align: right; flex-shrink: 0; }
</style>
</head>
<body>
<h1>Raft Metrics Dashboard</h1>
<p class="subtitle">Auto-refreshes every 3 seconds &nbsp;·&nbsp; Node: {{NODE_ID}} &nbsp;·&nbsp; State: <strong>{{STATE}}</strong></p>

<div class="section">Raft node</div>
<div class="grid">
  <div class="card">
    <div class="card-label">State</div>
    <div class="card-value {{STATE_COLOR}}">{{STATE}}</div>
  </div>
  <div class="card">
    <div class="card-label">Commit index</div>
    <div class="card-value blue">{{COMMIT_INDEX}}</div>
    <div class="card-sub">log entries committed</div>
  </div>
  <div class="card">
    <div class="card-label">Last log index</div>
    <div class="card-value blue">{{LAST_LOG_INDEX}}</div>
    <div class="card-sub">log entries written</div>
  </div>
  <div class="card">
    <div class="card-label">FSM pending</div>
    <div class="card-value {{FSM_COLOR}}">{{FSM_PENDING}}</div>
    <div class="card-sub">entries queued</div>
  </div>
  <div class="card">
    <div class="card-label">Term</div>
    <div class="card-value">{{TERM}}</div>
    <div class="card-sub">current election term</div>
  </div>
  <div class="card">
    <div class="card-label">Applied index</div>
    <div class="card-value blue">{{APPLIED_INDEX}}</div>
    <div class="card-sub">entries applied to FSM</div>
  </div>
</div>

<div class="section">Go runtime</div>
<div class="grid">
  <div class="card">
    <div class="card-label">Goroutines</div>
    <div class="card-value">{{GOROUTINES}}</div>
  </div>
  <div class="card">
    <div class="card-label">Heap in use</div>
    <div class="card-value">{{HEAP_MB}}</div><span class="card-unit">MB</span>
  </div>
  <div class="card">
    <div class="card-label">GC cycles</div>
    <div class="card-value">{{GC_COUNT}}</div>
  </div>
  <div class="card">
    <div class="card-label">Go version</div>
    <div class="card-value" style="font-size:16px">{{GO_VERSION}}</div>
  </div>
</div>

<div class="section">All raft stats</div>
{{STATS_ROWS}}

<p style="font-size:12px;color:#bbb;margin-top:24px;">Raw metrics: <a href="/metrics" style="color:#888">/metrics</a></p>
</body>
</html>`

func fmtBytes(b uint64) string {
	mb := float64(b) / 1024 / 1024
	return fmt.Sprintf("%.1f", mb)
}

func dashboardHandler(w http.ResponseWriter, r *http.Request) {
	stats := globalRaft.Stats()

	state := stats["state"]
	stateColor := "green"
	if state != "Leader" && state != "Follower" {
		stateColor = "amber"
	}

	fsmPending := stats["fsm_pending"]
	fsmColor := "green"
	if fsmPending != "0" {
		fsmColor = "amber"
	}

	var statsRows string
	keys := []string{"commit_index", "applied_index", "fsm_pending", "last_log_index", "last_log_term", "last_snapshot_index", "last_snapshot_term", "latest_configuration", "latest_configuration_index", "num_peers", "protocol_version", "protocol_version_max", "protocol_version_min", "snapshot_version_max", "snapshot_version_min", "state", "term"}
	for _, k := range keys {
		v, ok := stats[k]
		if !ok {
			continue
		}
		statsRows += fmt.Sprintf(`<div class="row-card"><div class="row-name">%s</div><div class="row-val">%s</div></div>`, k, v)
	}

	var memStats runtime_memstats
	readMemStats(&memStats)

	html := dashboardHTML
	html = replaceAll(html, "{{NODE_ID}}", stats["last_contact"])
	html = replaceAll(html, "{{STATE}}", state)
	html = replaceAll(html, "{{STATE_COLOR}}", stateColor)
	html = replaceAll(html, "{{COMMIT_INDEX}}", stats["commit_index"])
	html = replaceAll(html, "{{LAST_LOG_INDEX}}", stats["last_log_index"])
	html = replaceAll(html, "{{FSM_PENDING}}", fsmPending)
	html = replaceAll(html, "{{FSM_COLOR}}", fsmColor)
	html = replaceAll(html, "{{TERM}}", stats["term"])
	html = replaceAll(html, "{{APPLIED_INDEX}}", stats["applied_index"])
	html = replaceAll(html, "{{GOROUTINES}}", fmt.Sprintf("%d", memStats.goroutines))
	html = replaceAll(html, "{{HEAP_MB}}", fmtBytes(memStats.heapAlloc))
	html = replaceAll(html, "{{GC_COUNT}}", fmt.Sprintf("%d", memStats.numGC))
	html = replaceAll(html, "{{GO_VERSION}}", "go1.25")
	html = replaceAll(html, "{{STATS_ROWS}}", statsRows)

	w.Header().Set("Content-Type", "text/html")
	fmt.Fprint(w, html)
}

func replaceAll(s, old, new string) string {
	result := ""
	for {
		idx := indexOf(s, old)
		if idx < 0 {
			result += s
			break
		}
		result += s[:idx] + new
		s = s[idx+len(old):]
	}
	return result
}

func indexOf(s, sub string) int {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

import "runtime"

type runtime_memstats struct {
	heapAlloc  uint64
	numGC      uint32
	goroutines int
}

func readMemStats(m *runtime_memstats) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	m.heapAlloc = ms.HeapAlloc
	m.numGC = ms.NumGC
	m.goroutines = runtime.NumGoroutine()
}

func main() {
	sink, err := prometheussink.NewPrometheusSink()
	if err != nil {
		log.Fatalf("Prometheus sink: %v", err)
	}
	cfg := gometrics.DefaultConfig("raft")
	cfg.EnableHostname = false
	if _, err := gometrics.NewGlobal(cfg, sink); err != nil {
		log.Fatalf("Metrics init: %v", err)
	}

	raftCfg := raft.DefaultConfig()
	raftCfg.LocalID = raft.ServerID("node-1")
	raftCfg.Logger = hclog.New(&hclog.LoggerOptions{
		Name:   "raft",
		Level:  hclog.Info,
		Output: os.Stdout,
	})
	raftCfg.HeartbeatTimeout = 500 * time.Millisecond
	raftCfg.ElectionTimeout  = 500 * time.Millisecond
	raftCfg.CommitTimeout    = 100 * time.Millisecond

	logStore    := raft.NewInmemStore()
	stableStore := raft.NewInmemStore()
	snapStore   := raft.NewInmemSnapshotStore()
	addr, transport := raft.NewInmemTransport("")

	bootstrapCfg := raft.Configuration{
		Servers: []raft.Server{
			{Suffrage: raft.Voter, ID: raftCfg.LocalID, Address: addr},
		},
	}
	if err := raft.BootstrapCluster(raftCfg, logStore, stableStore, snapStore, transport, bootstrapCfg); err != nil {
		log.Fatalf("Bootstrap: %v", err)
	}

	r, err := raft.NewRaft(raftCfg, &simpleFSM{}, logStore, stableStore, snapStore, transport)
	if err != nil {
		log.Fatalf("NewRaft: %v", err)
	}
	globalRaft = r

	fmt.Println("[raft] Waiting for leader election...")
	for r.State() != raft.Leader {
		time.Sleep(100 * time.Millisecond)
	}
	fmt.Println("[raft] Leader elected ✓")

	go func() {
		for i := 0; ; i++ {
			if err := r.Apply([]byte(fmt.Sprintf("cmd-%d", i)), 500*time.Millisecond).Error(); err != nil {
				log.Printf("[warn] Apply: %v", err)
			}
			time.Sleep(300 * time.Millisecond)
		}
	}()

	http.Handle("/metrics", promhttp.Handler())
	http.HandleFunc("/dashboard", dashboardHandler)
	http.HandleFunc("/stats", func(w http.ResponseWriter, _ *http.Request) {
		for k, v := range r.Stats() {
			fmt.Fprintf(w, "%s = %s\n", k, v)
		}
	})
	http.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "state: %s\n", r.State())
	})
	http.HandleFunc("/", func(w http.ResponseWriter, req *http.Request) {
		http.Redirect(w, req, "/dashboard", http.StatusFound)
	})

	fmt.Println("\n[server] Listening on :9090")
	fmt.Println("  http://localhost:9090/dashboard  <- Visual dashboard")
	fmt.Println("  http://localhost:9090/metrics    <- Raw Prometheus")
	fmt.Println("  http://localhost:9090/stats      <- Plain text stats")
	fmt.Println("\nPress Ctrl+C to stop")
	log.Fatal(http.ListenAndServe(":9090", nil))
}
GOEOF

# Fix the import placement (move runtime import to top)
cat > main.go << 'GOEOF'
package main

import (
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"runtime"
	"strings"
	"time"

	"github.com/hashicorp/go-hclog"
	gometrics "github.com/hashicorp/go-metrics"
	prometheussink "github.com/hashicorp/go-metrics/prometheus"
	"github.com/hashicorp/raft"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

type fsmSnapshot struct{}
func (s *fsmSnapshot) Persist(sink raft.SnapshotSink) error { return sink.Close() }
func (s *fsmSnapshot) Release()                              {}

type simpleFSM struct{}
func (f *simpleFSM) Apply(l *raft.Log) interface{}       { return nil }
func (f *simpleFSM) Snapshot() (raft.FSMSnapshot, error) { return &fsmSnapshot{}, nil }
func (f *simpleFSM) Restore(rc io.ReadCloser) error      { return rc.Close() }

var globalRaft *raft.Raft

func fmtBytes(b uint64) string {
	return fmt.Sprintf("%.1f", float64(b)/1024/1024)
}

func dashboardHandler(w http.ResponseWriter, r *http.Request) {
	stats := globalRaft.Stats()
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)

	state := stats["state"]
	stateColor := "#2d7a3a"
	if state == "Candidate" { stateColor = "#b06000" }
	if state == "Shutdown"  { stateColor = "#b02020" }

	fsmPending := stats["fsm_pending"]
	fsmColor := "#2d7a3a"
	if fsmPending != "0" { fsmColor = "#b06000" }

	var rows strings.Builder
	ordered := []string{"state","term","commit_index","applied_index","fsm_pending","last_log_index","last_log_term","last_snapshot_index","last_snapshot_term","num_peers","protocol_version","latest_configuration_index"}
	for _, k := range ordered {
		v, ok := stats[k]
		if !ok { continue }
		rows.WriteString(fmt.Sprintf(`<div style="display:flex;align-items:center;padding:10px 0;border-bottom:1px solid #f0f0f0;"><div style="font-size:13px;color:#666;width:240px;flex-shrink:0;">%s</div><div style="font-size:13px;font-weight:600;">%s</div></div>`, k, v))
	}

	html := fmt.Sprintf(`<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta http-equiv="refresh" content="2">
<title>Raft Dashboard</title>
<style>
*{box-sizing:border-box;margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
body{background:#f4f4f6;padding:28px;color:#1a1a1a}
h1{font-size:22px;font-weight:600;margin-bottom:4px}
.sub{font-size:13px;color:#888;margin-bottom:28px}
.sec{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;color:#aaa;margin:24px 0 12px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:8px}
.mc{background:#fff;border-radius:12px;padding:16px 18px;border:1px solid #e8e8e8}
.ml{font-size:12px;color:#999;margin-bottom:6px}
.mv{font-size:24px;font-weight:600}
.mu{font-size:12px;color:#999;margin-left:2px;font-weight:400}
.ms{font-size:11px;color:#bbb;margin-top:4px}
.card{background:#fff;border-radius:12px;padding:16px 18px;border:1px solid #e8e8e8;margin-bottom:8px}
a{color:#888;font-size:12px}
</style></head>
<body>
<h1>Raft metrics dashboard</h1>
<p class="sub">Refreshes every 2s &nbsp;·&nbsp; Node: node-1 &nbsp;·&nbsp; State: <strong style="color:%s">%s</strong></p>

<div class="sec">Raft node</div>
<div class="grid">
  <div class="mc"><div class="ml">State</div><div class="mv" style="color:%s">%s</div></div>
  <div class="mc"><div class="ml">Commit index</div><div class="mv" style="color:#185fa5">%s</div><div class="ms">entries committed</div></div>
  <div class="mc"><div class="ml">Applied index</div><div class="mv" style="color:#185fa5">%s</div><div class="ms">entries in FSM</div></div>
  <div class="mc"><div class="ml">Last log index</div><div class="mv" style="color:#185fa5">%s</div><div class="ms">entries written</div></div>
  <div class="mc"><div class="ml">FSM pending</div><div class="mv" style="color:%s">%s</div><div class="ms">queued entries</div></div>
  <div class="mc"><div class="ml">Term</div><div class="mv">%s</div><div class="ms">election term</div></div>
</div>

<div class="sec">Go runtime</div>
<div class="grid">
  <div class="mc"><div class="ml">Goroutines</div><div class="mv">%d</div></div>
  <div class="mc"><div class="ml">Heap in use</div><div class="mv">%s<span class="mu">MB</span></div></div>
  <div class="mc"><div class="ml">GC cycles</div><div class="mv">%d</div></div>
  <div class="mc"><div class="ml">Go version</div><div class="mv" style="font-size:16px">%s</div></div>
</div>

<div class="sec">All raft stats</div>
<div class="card">%s</div>

<p style="margin-top:16px">Raw Prometheus: <a href="/metrics">/metrics</a> &nbsp;·&nbsp; <a href="/stats">plain stats</a></p>
</body></html>`,
		stateColor, state,
		stateColor, state,
		stats["commit_index"],
		stats["applied_index"],
		stats["last_log_index"],
		fsmColor, fsmPending,
		stats["term"],
		runtime.NumGoroutine(),
		fmtBytes(ms.HeapAlloc),
		ms.NumGC,
		runtime.Version(),
		rows.String(),
	)

	w.Header().Set("Content-Type", "text/html")
	fmt.Fprint(w, html)
}

func main() {
	sink, err := prometheussink.NewPrometheusSink()
	if err != nil { log.Fatalf("Prometheus sink: %v", err) }
	cfg := gometrics.DefaultConfig("raft")
	cfg.EnableHostname = false
	if _, err := gometrics.NewGlobal(cfg, sink); err != nil { log.Fatalf("Metrics init: %v", err) }

	raftCfg := raft.DefaultConfig()
	raftCfg.LocalID = raft.ServerID("node-1")
	raftCfg.Logger = hclog.New(&hclog.LoggerOptions{Name: "raft", Level: hclog.Info, Output: os.Stdout})
	raftCfg.HeartbeatTimeout = 500 * time.Millisecond
	raftCfg.ElectionTimeout  = 500 * time.Millisecond
	raftCfg.CommitTimeout    = 100 * time.Millisecond

	logStore    := raft.NewInmemStore()
	stableStore := raft.NewInmemStore()
	snapStore   := raft.NewInmemSnapshotStore()
	addr, transport := raft.NewInmemTransport("")

	if err := raft.BootstrapCluster(raftCfg, logStore, stableStore, snapStore, transport, raft.Configuration{
		Servers: []raft.Server{{Suffrage: raft.Voter, ID: raftCfg.LocalID, Address: addr}},
	}); err != nil { log.Fatalf("Bootstrap: %v", err) }

	r, err := raft.NewRaft(raftCfg, &simpleFSM{}, logStore, stableStore, snapStore, transport)
	if err != nil { log.Fatalf("NewRaft: %v", err) }
	globalRaft = r

	fmt.Println("[raft] Waiting for leader election...")
	for r.State() != raft.Leader { time.Sleep(100 * time.Millisecond) }
	fmt.Println("[raft] Leader elected ✓")

	go func() {
		for i := 0; ; i++ {
			r.Apply([]byte(fmt.Sprintf("cmd-%d", i)), 500*time.Millisecond)
			time.Sleep(300 * time.Millisecond)
		}
	}()

	http.Handle("/metrics", promhttp.Handler())
	http.HandleFunc("/dashboard", dashboardHandler)
	http.HandleFunc("/stats", func(w http.ResponseWriter, _ *http.Request) {
		for k, v := range r.Stats() { fmt.Fprintf(w, "%s = %s\n", k, v) }
	})
	http.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "state: %s\n", r.State())
	})
	http.HandleFunc("/", func(w http.ResponseWriter, req *http.Request) {
		http.Redirect(w, req, "/dashboard", http.StatusFound)
	})

	fmt.Println("\n[server] Open in browser: http://localhost:9090/dashboard")
	fmt.Println("Press Ctrl+C to stop")
	log.Fatal(http.ListenAndServe(":9090", nil))
}
GOEOF

# =============================================================================
# 7. FETCH DEPENDENCIES
# =============================================================================
info "Fetching dependencies..."
go get github.com/hashicorp/go-metrics@latest
go get github.com/hashicorp/go-metrics/prometheus@latest
go get github.com/hashicorp/go-hclog@latest
go get github.com/prometheus/client_golang/prometheus/promhttp@latest
go mod tidy

# =============================================================================
# 8. BUILD
# =============================================================================
info "Building with -tags hashicorpmetrics..."
go build -tags hashicorpmetrics -o "$DEMO_DIR/raft-demo" .
info "Binary: $DEMO_DIR/raft-demo ✓"

# =============================================================================
# 9. PROMETHEUS CONFIG
# =============================================================================
cat > "$DEMO_DIR/prometheus.yml" << 'PROMEOF'
global:
  scrape_interval: 5s
scrape_configs:
  - job_name: "salemmohammed-raft"
    static_configs:
      - targets: ["localhost:9090"]
PROMEOF

# =============================================================================
# 10. DONE
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Done!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  Start the demo:"
echo "    $DEMO_DIR/raft-demo"
echo ""
echo "  Then open:"
echo "    http://localhost:9090/dashboard  <- Visual dashboard"
echo "    http://localhost:9090/metrics    <- Raw Prometheus"
echo "    http://localhost:9090/stats      <- Plain text"
echo ""