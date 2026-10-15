# Oracle Always Free A1 — GitHub OIDC scheduled retry

STATUS: CODE INSTALLED; AUTHENTICATION NOT CONFIGURED; NO VPS CREATION VERIFIED.

The prior manual Oracle Cloud Shell run in the Tokyo region reached OutOfHostCapacity. This setup does not grant GitHub OCI privileges until an administrator completes the Oracle IAM configuration, secret setup and explicit enable switch.

## Files and behavior

- .github/workflows/oci-a1-retry.yml: every six hours + manual Run workflow; job DISABLED unless variable OCI_AUTO_ENABLED=true.
- life-os/oracle/github_oidc_login.py: obtains a GitHub OIDC JWT, checks issuer/audience/repository/ref/workflow_ref claims, exchanges for an OCI RPST using an Identity Domain OAuth confidential client. It does NOT require a long-lived OCI API signing key, but it DOES require an OAuth client secret.
- life-os/oracle/oci-identity-trust.example.json: a narrowly scoped trust template, not an active Oracle trust.
- life-os/oracle/bootstrap.sh: Only A1.Flex at 2 OCPU/12 GB or 1 OCPU/6 GB with 50 GB boot volume; audits existing free resource usage, reuses VCN, and never selects paid shapes. GitHub requires a persistent SSH public key instead of an ephemeral private key.
- The browser-based ChatGPT A-to-B auto-extraction/relay is not deployed.

## Oracle IAM administrator prerequisite (not completed)

Official guide: https://docs.oracle.com/en-us/iaas/Content/Identity/api-getstarted/token_exchange_grant_type_workload_id-federation.htm

1. In the tenancy's OCI Identity Domain, create a non-admin OAuth Confidential Application allowed to exchange JWTs for RPST. Keep its client ID and client secret. Do NOT store an administrator application's credentials in GitHub.
2. Configure an active IdentityPropagationTrust using the included JSON template (replace the placeholder OAuth client ID). Issuer: https://token.actions.githubusercontent.com . JWKS endpoint: https://token.actions.githubusercontent.com/.well-known/jwks . Resource type: githubactions. Require claims repository=CHEMOPHILIA/CHEMISTRY, repository_owner=CHEMOPHILIA, ref=refs/heads/main, workflow_ref=CHEMOPHILIA/CHEMISTRY/.github/workflows/oci-a1-retry.yml@refs/heads/main, aud=github-actions. This Trust needs to be created via an authorized Identity Domain admin REST operation.
3. Configure a least-privilege OCI IAM policy for that trusted resource to inspect existing compartments/instances/volumes/VCN and manage just the necessary compute/network/boot volumes in the intended compartment. Prefer dedicated compartment and quota limits. This policy's exact matching conditions have NOT been tested and must be confirmed with OCI; DO NOT grant unconditional tenancy-wide manage all-resources.

## GitHub repository settings

Go to https://github.com/CHEMOPHILIA/CHEMISTRY/settings/secrets/actions
Add three Actions Secrets:
- OCI_WIF_CLIENT_SECRET = OAuth non-admin confidential application client secret
- OCI_TENANCY_OCID = your tenancy OCID
- OCI_SSH_PUBLIC_KEY = existing Oracle Cloud Shell RSA public key (output of: cat ~/.ssh/life-os-rsa4096.pub). The private key must stay in Cloud Shell.

Go to https://github.com/CHEMOPHILIA/CHEMISTRY/settings/variables/actions
Add three Actions Variables:
- OCI_WIF_DOMAIN_URL = https://idcs-...identity.oraclecloud.com (your real base URL)
- OCI_WIF_CLIENT_ID = OAuth non-admin application client ID
- OCI_AUTO_ENABLED = false until Oracle trust, IAM policy, account quotas and keys are confirmed; THEN set true.

Do not paste API keys, OAuth secrets, GitHub OIDC JWTs, SSH private keys or RPSTs into issues, logs, commits, or chat.

## Running and stopping

When settings and Oracle trust are ready, use https://github.com/CHEMOPHILIA/CHEMISTRY/actions/workflows/oci-a1-retry.yml (Run workflow). Scheduled checks run every 6 hours, subject to GitHub's normal scheduling delays. If a life-os VM already exists, later runs skip creating another. If A1 capacity is missing, a bounded attempt fails and waits for the next scheduled run. Set OCI_AUTO_ENABLED=false to stop. The temporary runner does not have the private key, and there are no internet-accessible SSH ingress rules.

## Unverified/critical limitations

- The GitHub-to-OCI exchange has NOT been tested against this account. OAuth application and Trust require one-time administrator configuration.
- The OCI CLI --auth security_token compatibility with the newly issued RPST must be verified by the smoke-test step.
- Oracle Tokyo A1 capacity remains unverified and may still be exhausted.
- Instance existence, SSH access, cloud-init Docker/snap Chromium installation, browser GUI and ChatGPT web-to-web behavior are NOT verified.
- OCI Cloud Shell Private Networking must be enabled for SSH, as SSH ingress is VCN-only.
- Although chosen compute shape / boot size are within published Always Free resource limits, actual cost eligibility requires validating all existing usage and account billing state.
- Automated ChatGPT web-output extraction is NOT permitted merely by running a browser on a VPS.

Official references:
- Oracle: https://docs.oracle.com/en-us/iaas/Content/Identity/api-getstarted/token_exchange_grant_type_workload_id-federation.htm
- GitHub OIDC: https://docs.github.com/en/actions/reference/security/oidc
- Oracle Always Free: https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
