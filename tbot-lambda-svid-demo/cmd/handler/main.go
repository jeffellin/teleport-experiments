// handler is the demo Lambda function. On every invoke it:
//
//  1. Asks the local SPIFFE Workload API (served by tbot, running as a Lambda
//     extension) for an X509-SVID. No secrets are baked into the function.
//  2. Opens a PostgreSQL connection using that SVID as the TLS client
//     certificate. Postgres is configured with `cert` auth and trusts the
//     Teleport cluster's SPIFFE CA, so no password is involved.
//  3. Runs a couple of queries and returns what it learned.
//
// Runtime: provided.al2023, binary name `bootstrap`.
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-lambda-go/lambdacontext"
	"github.com/jackc/pgx/v5"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

type response struct {
	SVID     svidInfo `json:"svid"`
	Database *dbInfo  `json:"database,omitempty"`
	Error    string   `json:"error,omitempty"`
	Timings  timings  `json:"timings_ms"`
}

type svidInfo struct {
	SPIFFEID  string    `json:"spiffe_id"`
	Subject   string    `json:"subject"`
	Serial    string    `json:"serial"`
	Issuer    string    `json:"issuer"`
	NotBefore time.Time `json:"not_before"`
	NotAfter  time.Time `json:"not_after"`
	Hint      string    `json:"hint,omitempty"`
}

type dbInfo struct {
	CurrentUser      string `json:"current_user"`
	ServerVersion    string `json:"server_version"`
	SSLClientDN      string `json:"ssl_client_dn"`
	TotalInvocations int64  `json:"total_invocations_recorded"`
}

type timings struct {
	FetchSVID int64 `json:"fetch_svid"`
	DBConnect int64 `json:"db_connect"`
	DBQuery   int64 `json:"db_query"`
}

func handle(ctx context.Context, _ map[string]any) (*response, error) {
	resp := &response{}
	requestID := ""
	if lc, ok := lambdacontext.FromContext(ctx); ok {
		requestID = lc.AwsRequestID
	}

	// 1. Fetch an X509-SVID from tbot's Workload API. go-spiffe reads the socket
	//    address from SPIFFE_ENDPOINT_SOCKET (set in the function env).
	t0 := time.Now()
	fetchCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	svid, err := workloadapi.FetchX509SVID(fetchCtx)
	cancel()
	resp.Timings.FetchSVID = time.Since(t0).Milliseconds()
	if err != nil {
		return nil, fmt.Errorf("fetching X509-SVID from workload API: %w", err)
	}
	resp.SVID = describe(svid)
	log.Printf("got SVID %s (serial %s, expires %s)", resp.SVID.SPIFFEID, resp.SVID.Serial, resp.SVID.NotAfter.Format(time.RFC3339))

	if os.Getenv("DB_HOST") == "" {
		resp.Error = "DB_HOST not set; skipping database step"
		return resp, nil
	}

	// 2. Connect to Postgres, presenting the SVID as the client certificate.
	t1 := time.Now()
	conn, err := connect(ctx, svid)
	resp.Timings.DBConnect = time.Since(t1).Milliseconds()
	if err != nil {
		resp.Error = fmt.Sprintf("db connect: %v", err)
		return resp, nil
	}
	defer conn.Close(context.Background())

	// 3. Prove who the database thinks we are.
	t2 := time.Now()
	info := &dbInfo{}
	err = conn.QueryRow(ctx, `
		SELECT current_user,
		       current_setting('server_version'),
		       COALESCE((SELECT client_dn FROM pg_stat_ssl WHERE pid = pg_backend_pid()), '')`,
	).Scan(&info.CurrentUser, &info.ServerVersion, &info.SSLClientDN)
	if err == nil {
		_, err = conn.Exec(ctx,
			`INSERT INTO lambda_invocations (request_id, spiffe_id, svid_serial) VALUES ($1, $2, $3)`,
			requestID, resp.SVID.SPIFFEID, resp.SVID.Serial)
	}
	if err == nil {
		err = conn.QueryRow(ctx, `SELECT count(*) FROM lambda_invocations`).Scan(&info.TotalInvocations)
	}
	resp.Timings.DBQuery = time.Since(t2).Milliseconds()
	if err != nil {
		resp.Error = fmt.Sprintf("db query: %v", err)
	}
	resp.Database = info
	return resp, nil
}

func connect(ctx context.Context, svid *x509svid.SVID) (*pgx.Conn, error) {
	host := os.Getenv("DB_HOST")
	sslmode := envOr("DB_SSLMODE", "verify-full")

	dsn := fmt.Sprintf("host=%s port=%s dbname=%s user=%s sslmode=require connect_timeout=5 application_name=tbot-lambda-demo",
		host, envOr("DB_PORT", "5432"), envOr("DB_NAME", "demo"), envOr("DB_USER", "lambda_svid_demo"))
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}

	tlsCfg, err := clientTLSConfig(svid, host, sslmode)
	if err != nil {
		return nil, err
	}
	cfg.TLSConfig = tlsCfg
	cfg.Fallbacks = nil // never fall back to a non-TLS connection

	cctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	return pgx.ConnectConfig(cctx, cfg)
}

// clientTLSConfig presents the SVID and (optionally) verifies the server.
//
//	DB_SSLMODE=verify-full  verify server cert against DB_SERVER_CA_PEM + hostname
//	DB_SSLMODE=require      encrypt + client cert, but don't verify the server (demo only)
func clientTLSConfig(svid *x509svid.SVID, host, sslmode string) (*tls.Config, error) {
	chain := make([][]byte, 0, len(svid.Certificates))
	for _, c := range svid.Certificates {
		chain = append(chain, c.Raw)
	}
	cfg := &tls.Config{
		MinVersion: tls.VersionTLS12,
		Certificates: []tls.Certificate{{
			Certificate: chain,
			PrivateKey:  svid.PrivateKey,
			Leaf:        svid.Certificates[0],
		}},
	}

	switch sslmode {
	case "verify-full":
		pem := os.Getenv("DB_SERVER_CA_PEM")
		if pem == "" {
			return nil, errors.New("DB_SSLMODE=verify-full requires DB_SERVER_CA_PEM (or set DB_SSLMODE=require for a quick demo)")
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM([]byte(pem)) {
			return nil, errors.New("DB_SERVER_CA_PEM contains no valid certificates")
		}
		cfg.RootCAs = pool
		cfg.ServerName = host
	case "require":
		cfg.InsecureSkipVerify = true //nolint:gosec // explicit demo mode
	default:
		return nil, fmt.Errorf("unsupported DB_SSLMODE %q (use verify-full or require)", sslmode)
	}
	return cfg, nil
}

func describe(s *x509svid.SVID) svidInfo {
	leaf := s.Certificates[0]
	return svidInfo{
		SPIFFEID:  s.ID.String(),
		Subject:   leaf.Subject.String(),
		Serial:    strings.ToLower(leaf.SerialNumber.Text(16)),
		Issuer:    leaf.Issuer.String(),
		NotBefore: leaf.NotBefore,
		NotAfter:  leaf.NotAfter,
		Hint:      s.Hint,
	}
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	lambda.Start(handle)
}
