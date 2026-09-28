// tbot-extension is an AWS Lambda *external extension* that runs Teleport's
// tbot alongside the function. tbot joins the Teleport cluster using the
// Lambda execution role (IAM join method) and serves the SPIFFE Workload API
// on a Unix socket in /tmp. The function code then requests SVIDs from that
// socket, exactly as it would on a VM or in Kubernetes.
//
// Lifecycle:
//
//	INIT     register with the Extensions API -> write tbot config -> start tbot
//	         -> wait until tbot reports ready -> call /event/next
//	         (Lambda does not run the first invoke until every extension has
//	          called /event/next, so the handler never races tbot.)
//	INVOKE   not subscribed; tbot just keeps running (frozen/thawed with the env)
//	SHUTDOWN SIGTERM tbot and exit.
//
// The layer ships two files:
//
//	/opt/extensions/tbot-extension   (this binary; the file name is the extension name)
//	/opt/bin/tbot                    (the upstream Teleport tbot binary)
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	extensionAPIVersion = "2020-01-01"
	defaultTbotPath     = "/opt/bin/tbot"
	defaultSocketPath   = "/tmp/tbot/workload.sock"
	defaultDiagAddr     = "127.0.0.1:3001"
	generatedConfigPath = "/tmp/tbot/tbot.yaml"
)

var logger = log.New(os.Stderr, "[tbot-extension] ", log.LstdFlags|log.Lmicroseconds)

type settings struct {
	tbotPath     string
	configPath   string // if set, used as-is instead of generating one
	proxyAddr    string
	joinToken    string
	joinMethod   string
	wiName       string
	socketPath   string
	diagAddr     string
	readyTimeout time.Duration
	debug        bool
}

func loadSettings() (settings, error) {
	s := settings{
		tbotPath:     envOr("TBOT_BINARY", defaultTbotPath),
		configPath:   os.Getenv("TBOT_CONFIG_PATH"),
		proxyAddr:    os.Getenv("TELEPORT_PROXY_ADDR"),
		joinToken:    os.Getenv("TBOT_JOIN_TOKEN"),
		joinMethod:   envOr("TBOT_JOIN_METHOD", "iam"),
		wiName:       os.Getenv("TBOT_WORKLOAD_IDENTITY"),
		socketPath:   strings.TrimPrefix(envOr("SPIFFE_ENDPOINT_SOCKET", "unix://"+defaultSocketPath), "unix://"),
		diagAddr:     envOr("TBOT_DIAG_ADDR", defaultDiagAddr),
		readyTimeout: 8 * time.Second,
		debug:        os.Getenv("TBOT_DEBUG") == "true",
	}
	if v := os.Getenv("TBOT_READY_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil {
			return s, fmt.Errorf("invalid TBOT_READY_TIMEOUT: %w", err)
		}
		s.readyTimeout = d
	}
	if s.configPath == "" {
		var missing []string
		for k, v := range map[string]string{
			"TELEPORT_PROXY_ADDR":    s.proxyAddr,
			"TBOT_JOIN_TOKEN":        s.joinToken,
			"TBOT_WORKLOAD_IDENTITY": s.wiName,
		} {
			if v == "" {
				missing = append(missing, k)
			}
		}
		if len(missing) > 0 {
			return s, fmt.Errorf("missing required env vars: %s", strings.Join(missing, ", "))
		}
	}
	return s, nil
}

// tbotConfig renders a minimal tbot v2 config: IAM join, in-memory storage
// (Lambda's filesystem is ephemeral anyway) and a single workload-identity-api
// service bound to a Unix socket.
func tbotConfig(s settings) string {
	return fmt.Sprintf(`version: v2
proxy_server: %q
onboarding:
  join_method: %q
  token: %q
storage:
  type: memory
services:
  - type: workload-identity-api
    listen: %q
    selector:
      name: %q
`, s.proxyAddr, s.joinMethod, s.joinToken, "unix://"+s.socketPath, s.wiName)
}

func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()

	api := newExtensionClient(os.Getenv("AWS_LAMBDA_RUNTIME_API"))
	extName := filepath.Base(os.Args[0])

	// Register first: Lambda requires this early in INIT. We only subscribe to
	// SHUTDOWN, so this extension adds zero latency to each invoke.
	if err := api.register(ctx, extName); err != nil {
		logger.Fatalf("register failed: %v", err)
	}
	logger.Printf("registered as %q", extName)

	s, err := loadSettings()
	if err != nil {
		api.initError(ctx, "Extension.ConfigError", err)
		logger.Fatalf("%v", err)
	}

	cfgPath := s.configPath
	if cfgPath == "" {
		if err := os.MkdirAll(filepath.Dir(generatedConfigPath), 0o700); err != nil {
			api.initError(ctx, "Extension.FSError", err)
			logger.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(generatedConfigPath, []byte(tbotConfig(s)), 0o600); err != nil {
			api.initError(ctx, "Extension.FSError", err)
			logger.Fatalf("write config: %v", err)
		}
		cfgPath = generatedConfigPath
	}
	if err := os.MkdirAll(filepath.Dir(s.socketPath), 0o755); err != nil {
		api.initError(ctx, "Extension.FSError", err)
		logger.Fatalf("mkdir socket dir: %v", err)
	}
	_ = os.Remove(s.socketPath) // stale socket from a previous (crashed) run

	sup := &supervisor{settings: s, configPath: cfgPath}
	start := time.Now()
	if err := sup.start(); err != nil {
		api.initError(ctx, "Extension.TbotStartError", err)
		logger.Fatalf("start tbot: %v", err)
	}

	if err := waitReady(ctx, s, sup); err != nil {
		sup.stop()
		api.initError(ctx, "Extension.TbotNotReady", err)
		logger.Fatalf("tbot not ready: %v", err)
	}
	logger.Printf("tbot ready in %s; workload API at unix://%s", time.Since(start).Round(time.Millisecond), s.socketPath)

	// From here on, restart tbot if it dies (e.g. transient network failure
	// while re-joining after a long freeze).
	go sup.keepAlive(ctx)

	for {
		ev, err := api.next(ctx)
		if err != nil {
			if ctx.Err() != nil {
				break
			}
			logger.Printf("event/next error: %v", err)
			time.Sleep(200 * time.Millisecond)
			continue
		}
		if ev.EventType == "SHUTDOWN" {
			logger.Printf("SHUTDOWN (%s)", ev.ShutdownReason)
			break
		}
	}
	sup.stop()
}

// waitReady polls tbot's diagnostics /readyz endpoint. If that endpoint is not
// available (older tbot), it falls back to "socket exists".
func waitReady(ctx context.Context, s settings, sup *supervisor) error {
	deadline := time.Now().Add(s.readyTimeout)
	client := &http.Client{Timeout: 500 * time.Millisecond}
	url := "http://" + s.diagAddr + "/readyz"
	for time.Now().Before(deadline) {
		if exited, err := sup.exited(); exited {
			return fmt.Errorf("tbot exited during startup: %v", err)
		}
		if resp, err := client.Get(url); err == nil {
			_, _ = io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	if _, err := os.Stat(s.socketPath); err == nil {
		logger.Printf("WARN: /readyz never returned 200 within %s, but socket exists; continuing", s.readyTimeout)
		return nil
	}
	return fmt.Errorf("timed out after %s waiting for tbot (check join token / IAM ARN / proxy reachability in the logs above)", s.readyTimeout)
}

// ---------------------------------------------------------------------------
// tbot process supervision
// ---------------------------------------------------------------------------

type supervisor struct {
	settings   settings
	configPath string

	mu      sync.Mutex
	cmd     *exec.Cmd
	done    chan struct{}
	exitErr error
	stopped bool
}

func (s *supervisor) start() error {
	args := []string{"start", "-c", s.configPath, "--diag-addr", s.settings.diagAddr}
	if s.settings.debug {
		args = append(args, "--debug")
	}
	cmd := exec.Command(s.settings.tbotPath, args...)
	cmd.Stdout = os.Stdout // goes to CloudWatch with the function logs
	cmd.Stderr = os.Stderr
	cmd.Env = os.Environ()
	if os.Getenv("HOME") == "" {
		cmd.Env = append(cmd.Env, "HOME=/tmp")
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan struct{})
	s.mu.Lock()
	s.cmd, s.done, s.exitErr = cmd, done, nil
	s.mu.Unlock()
	go func() {
		err := cmd.Wait()
		s.mu.Lock()
		s.exitErr = err
		s.mu.Unlock()
		close(done)
	}()
	logger.Printf("started tbot pid=%d args=%v", cmd.Process.Pid, args)
	return nil
}

func (s *supervisor) exited() (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.done:
		return true, s.exitErr
	default:
		return false, nil
	}
}

func (s *supervisor) keepAlive(ctx context.Context) {
	backoff := time.Second
	for {
		s.mu.Lock()
		done := s.done
		s.mu.Unlock()
		select {
		case <-ctx.Done():
			return
		case <-done:
		}
		s.mu.Lock()
		stopped, err := s.stopped, s.exitErr
		s.mu.Unlock()
		if stopped {
			return
		}
		logger.Printf("tbot exited unexpectedly (%v); restarting in %s", err, backoff)
		time.Sleep(backoff)
		_ = os.Remove(s.settings.socketPath)
		if err := s.start(); err != nil {
			logger.Printf("restart failed: %v", err)
		}
		if backoff < 30*time.Second {
			backoff *= 2
		}
	}
}

func (s *supervisor) stop() {
	s.mu.Lock()
	s.stopped = true
	cmd, done := s.cmd, s.done
	s.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(1500 * time.Millisecond): // Lambda gives extensions ~2s on SHUTDOWN
		_ = cmd.Process.Kill()
	}
}

// ---------------------------------------------------------------------------
// Minimal Lambda Extensions API client
// https://docs.aws.amazon.com/lambda/latest/dg/runtimes-extensions-api.html
// ---------------------------------------------------------------------------

type extensionClient struct {
	base string
	id   string
	http *http.Client
}

type event struct {
	EventType      string `json:"eventType"`
	DeadlineMs     int64  `json:"deadlineMs"`
	RequestID      string `json:"requestId"`
	ShutdownReason string `json:"shutdownReason"`
}

func newExtensionClient(runtimeAPI string) *extensionClient {
	return &extensionClient{
		base: fmt.Sprintf("http://%s/%s/extension", runtimeAPI, extensionAPIVersion),
		http: &http.Client{}, // no timeout: /event/next long-polls
	}
}

func (c *extensionClient) register(ctx context.Context, name string) error {
	body, _ := json.Marshal(map[string][]string{"events": {"SHUTDOWN"}})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/register", bytes.NewReader(body))
	req.Header.Set("Lambda-Extension-Name", name)
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("status %d: %s", resp.StatusCode, b)
	}
	c.id = resp.Header.Get("Lambda-Extension-Identifier")
	if c.id == "" {
		return errors.New("no Lambda-Extension-Identifier in register response")
	}
	return nil
}

func (c *extensionClient) next(ctx context.Context) (*event, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/event/next", nil)
	req.Header.Set("Lambda-Extension-Identifier", c.id)
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("status %d: %s", resp.StatusCode, b)
	}
	var ev event
	if err := json.NewDecoder(resp.Body).Decode(&ev); err != nil {
		return nil, err
	}
	return &ev, nil
}

// initError tells Lambda that INIT failed, so the environment is torn down and
// the error surfaces clearly instead of as a confusing handler failure.
func (c *extensionClient) initError(ctx context.Context, errType string, cause error) {
	if c.id == "" {
		return
	}
	body, _ := json.Marshal(map[string]any{"errorMessage": cause.Error(), "errorType": errType})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, c.base+"/init/error", bytes.NewReader(body))
	req.Header.Set("Lambda-Extension-Identifier", c.id)
	req.Header.Set("Lambda-Extension-Function-Error-Type", errType)
	if resp, err := c.http.Do(req); err == nil {
		resp.Body.Close()
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
