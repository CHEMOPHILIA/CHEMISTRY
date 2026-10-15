#!/usr/bin/env python3
"""Exchange GitHub Actions OIDC JWT for an OCI RPST using official IAM token exchange.

No OCI long-lived API key. IAM confidential-client secret is still required.
Never print JWTs, RPSTs, private keys, or OAuth client secrets.
"""
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request


def require(name):
    val = os.environ.get(name, "").strip()
    if not val:
        raise ValueError(f"Missing {name}")
    return val


def json_request(url, *, data=None, headers=None, method=None):
    request = urllib.request.Request(
        url,
        data=data,
        headers=headers or {},
        method=method or ("POST" if data is not None else "GET"),
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        # The body can include OAuth credentials or tokens. Do not print it.
        raise RuntimeError(f"OCI/GitHub authentication HTTP {exc.code}") from None


def jwt_payload(token):
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("Malformed OIDC JWT")
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def main():
    assert os.environ.get("GITHUB_REPOSITORY") == "CHEMOPHILIA/CHEMISTRY", "Wrong repository"
    assert os.environ.get("GITHUB_REF") == "refs/heads/main", "Wrong git ref"
    expected_workflow = (
        "CHEMOPHILIA/CHEMISTRY/.github/workflows/oci-a1-retry.yml@refs/heads/main"
    )
    domain = require("OCI_WIF_DOMAIN_URL").rstrip("/")
    parsed = urllib.parse.urlparse(domain)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or not parsed.hostname.endswith(".identity.oraclecloud.com")
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
        or parsed.username
    ):
        raise ValueError("Invalid OCI Identity Domain base URL")
    tenancy = require("OCI_TENANCY_OCID")
    if not tenancy.startswith("ocid1.tenancy."):
        raise ValueError("Invalid tenancy OCID")
    client_id = require("OCI_WIF_CLIENT_ID")
    client_secret = require("OCI_WIF_CLIENT_SECRET")
    request_url = require("ACTIONS_ID_TOKEN_REQUEST_URL")
    request_bearer = require("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    audience = "github-actions"

    separator = "&" if "?" in request_url else "?"
    github_token = json_request(
        request_url + separator + urllib.parse.urlencode({"audience": audience}),
        headers={"Authorization": f"bearer {request_bearer}"},
    ).get("value")
    if not github_token:
        raise RuntimeError("GitHub returned no OIDC JWT")
    claims = jwt_payload(github_token)
    for field, expected in (
        ("iss", "https://token.actions.githubusercontent.com"),
        ("aud", audience),
        ("repository", "CHEMOPHILIA/CHEMISTRY"),
        ("ref", "refs/heads/main"),
        ("workflow_ref", expected_workflow),
    ):
        if claims.get(field) != expected:
            raise RuntimeError(f"GitHub OIDC claim mismatch: {field}")

    home = Path(tempfile.mkdtemp(prefix="oci-wif-", dir=require("RUNNER_TEMP")))
    os.chmod(home, 0o700)
    key_file = home / "key.pem"
    pub_file = home / "public.pem"
    token_file = home / "session.token"
    config_file = home / "config"
    subprocess.run(
        ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048",
         "-out", str(key_file)],
        check=True, capture_output=True,
    )
    subprocess.run(
        ["openssl", "pkey", "-in", str(key_file), "-pubout", "-out", str(pub_file)],
        check=True, capture_output=True,
    )
    os.chmod(key_file, 0o600)
    pub = pub_file.read_text(encoding="utf-8")
    body = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
        "requested_token_type": "urn:oci:token-type:oci-rpst",
        "public_key": pub,
        "subject_token": github_token,
        "subject_token_type": "jwt",
        "res_type": "githubactions",
        "rpst_exp": "60",
    }).encode()
    basic = base64.b64encode((client_id + ":" + client_secret).encode()).decode()
    exchange = json_request(
        domain + "/oauth2/v1/token",
        data=body,
        headers={
            "Authorization": "Basic " + basic,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    rpst = exchange.get("token")
    if not isinstance(rpst, str) or not rpst:
        raise RuntimeError("OCI did not issue an RPST")
    token_file.write_text(rpst, encoding="utf-8")
    os.chmod(token_file, 0o600)
    config_file.write_text(
        "[ap-tokyo-1]\n"
        f"tenancy={tenancy}\n"
        "region=ap-tokyo-1\n"
        f"key_file={key_file}\n"
        f"security_token_file={token_file}\n",
        encoding="utf-8",
    )
    os.chmod(config_file, 0o600)
    env_file = Path(require("GITHUB_ENV"))
    with env_file.open("a", encoding="utf-8") as handle:
        handle.write(f"OCI_CLI_CONFIG_FILE={config_file}\n")
        handle.write("OCI_CLI_PROFILE=ap-tokyo-1\n")
        handle.write("OCI_CLI_AUTH=security_token\n")
        handle.write(f"OCI_CLI_TENANCY={tenancy}\n")
    print("GitHub OIDC -> OCI RPST exchange completed; temporary OCI CLI profile ready.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"OCI federation failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
