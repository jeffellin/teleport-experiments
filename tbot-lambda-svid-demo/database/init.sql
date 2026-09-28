-- Role the Lambda authenticates as. No password: the only way in is a client
-- cert with CN=lambda_svid_demo signed by the Teleport SPIFFE CA.
CREATE ROLE lambda_svid_demo LOGIN;

CREATE TABLE lambda_invocations (
    id          bigserial PRIMARY KEY,
    request_id  text        NOT NULL,
    spiffe_id   text        NOT NULL,
    svid_serial text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON lambda_invocations TO lambda_svid_demo;
GRANT USAGE ON SEQUENCE lambda_invocations_id_seq TO lambda_svid_demo;
