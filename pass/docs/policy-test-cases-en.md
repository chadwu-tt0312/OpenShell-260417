# Policy Test Case List

- `c01` L4 allow/deny (`host + port` basic network policy)
- `c02` L7 `access: read-only` (`enforce`)
- `c03` L7 `access: read-write` (`enforce`)
- `c04` L7 `access: full` (`enforce`)
- `c05` L7 explicit `rules` (method + path)
- `c06` `enforcement: audit` behavior
- `c07` `tls: skip` behavior
- `c08` binary wildcard path matching
- `c09` host wildcard matching (`*.github.com`)
- `c10` multi-port endpoint (`ports`)
- `c11` `allowed_ips` invalid loopback rejection
- `c12` hostless `allowed_ips` schema acceptance

## Source Mapping

- `docs/reference/policy-schema.md`
- `architecture/security-policy.md`
- `docs/tutorials/first-network-policy.md`
- `docs/sandboxes/policies.md`
- `.agents/skills/generate-sandbox-policy/examples.md`

## Artifact Export (policy-validation-20260420t082754z)

### Overview

- `pass/artifacts/policy-validation-20260420t082754z/policies`: test input policies generated per case (`c01`~`c12`)
- `pass/artifacts/policy-validation-20260420t082754z/raw`: execution evidence (preflight logs, policy apply output, HTTP probe results)
- `pass/artifacts/policy-validation-20260420t082754z/raw/*.plain.txt`: ANSI-stripped outputs for easier diff/CI parsing
- `pass/artifacts/policy-validation-20260420t082754z/raw/*.request.txt`: exact HTTP probe command snapshots
- `pass/artifacts/policy-validation-20260420t082754z/raw/*.result.json`: structured HTTP probe diagnosis (`http_code`, `curl_exit_code`, `policy_decision_hint`)

### policies/

- `bootstrap.yaml`: sandbox bootstrap policy; base filesystem/process settings with `network_policies: {}`
- `c01_l4.yaml`: L4 allow/deny baseline; allow `api.github.com:443` for `/usr/bin/curl`
- `c02_l7_readonly.yaml`: L7 `access: read-only` with `enforcement: enforce`
- `c03_l7_readwrite.yaml`: L7 `access: read-write` with `enforcement: enforce`
- `c04_l7_full.yaml`: L7 `access: full` with `enforcement: enforce`
- `c05_rules.yaml`: explicit L7 rules; allow `GET /zen` and `GET /meta` only
- `c06_audit.yaml`: L7 `access: read-only` with `enforcement: audit`
- `c07_tls_skip.yaml`: endpoint with `tls: skip` behavior
- `c08_binary_wildcard.yaml`: binary wildcard match using `"/usr/bin/*"`
- `c09_host_wildcard.yaml`: host wildcard match using `"*.github.com"`
- `c10_multi_port.yaml`: multi-port endpoint using `ports: [443, 8443]`
- `c11_allowed_ips_linklocal.yaml`: link-local `169.254.169.254/32` in `allowed_ips` (must still be blocked)
- `c12_hostless_allowed_ips.yaml`: hostless endpoint schema acceptance (`port + allowed_ips`)

### raw/

#### Flow and Summary Files

- `run.log`: end-to-end timeline; preflight -> `c01`~`c12` -> completion -> cleanup
- `summary.txt`: case summary; all `c01`~`c12` recorded as PASS
- `ssh_config_policy-matrix-20260420t082754z`: generated SSH config for sandbox command execution via `openshell ssh-proxy`
- `preflight_status.txt`: gateway health check output (`Connected`, server URL, version)
- `preflight_sandbox_create.txt`: sandbox creation progress, image pull logs, final `ready`
- `preflight_sandbox_list.txt`: sandbox list poll result showing target sandbox `Ready`

#### Per-case policy apply files (`cXX_policy_set.txt`)

- `c01_policy_set.txt`: Policy version `2` submitted/loaded (hash `6598006a1fcd`)
- `c02_policy_set.txt`: Policy version `3` submitted/loaded (hash `65f78a782791`)
- `c03_policy_set.txt`: Policy version `4` submitted/loaded (hash `d9cfff1591c5`)
- `c04_policy_set.txt`: Policy version `5` submitted/loaded (hash `3dc6fa7eea6e`)
- `c05_policy_set.txt`: Policy version `6` submitted/loaded (hash `d08217f37218`)
- `c06_policy_set.txt`: Policy version `7` submitted/loaded (hash `2f70f19b44eb`)
- `c07_policy_set.txt`: Policy version `8` submitted/loaded (hash `df13e67a6845`)
- `c08_policy_set.txt`: Policy version `9` submitted/loaded (hash `26ce6705ab70`)
- `c09_policy_set.txt`: Policy version `10` submitted/loaded (hash `0dce99e68b19`)
- `c10_policy_set.txt`: Policy version `11` submitted/loaded (hash `4d549a4e6377`)
- `c11_policy_set.txt`: Policy version `12` submitted/loaded (hash `0e3cd16e8cc9`)
- `c12_policy_set.txt`: Policy version `13` submitted/loaded (hash `c883f558d5aa`)

#### Per-case HTTP/result evidence

- `c01_allow.txt`: `200` (allowed host)
- `c01_deny_other_host.txt`: `000` + `CONNECT tunnel failed, response 403` (denied non-allowed host)
- `c02_allow_get.txt`: `200` (GET allowed in read-only)
- `c02_deny_post.txt`: `403` (POST denied in read-only enforce)
- `c03_post_not_policy_denied.txt`: `401` (upstream deny, not policy `403`)
- `c03_delete_denied.txt`: `403` (DELETE denied under read-write preset)
- `c04_delete_not_policy_denied.txt`: `404` (not policy `403`, confirms full access passthrough)
- `c05_allow_specific.txt`: `200` (listed rule path allowed)
- `c05_deny_unlisted.txt`: `403` (unlisted path denied)
- `c06_post_audit.txt`: `401` (audit mode does not enforce policy `403`)
- `c07_allow_l4_with_skip.txt`: `200` (`tls: skip` scenario succeeds)
- `c08_allow_curl_by_wildcard.txt`: `200` (binary wildcard applied)
- `c09_allow_api_github.txt`: `200` (host wildcard includes `api.github.com`)
- `c09_deny_httpbin.txt`: `000` + `CONNECT tunnel failed, response 403` (outside wildcard denied)
- `c10_allow_443.txt`: `200` (multi-port policy includes `443`)
- `c11_linklocal_still_blocked.txt`: `403` (link-local remains blocked)
- `c12_policy_set_invalid_schema.txt`: negative schema validation; invalid policy must be rejected by `openshell policy set`

#### Structured probe artifacts

- For each HTTP check step, three files are produced together:
  - `<case>_<step>.txt`: raw curl output (status code and possible curl error text)
  - `<case>_<step>.request.txt`: exact command executed in sandbox
  - `<case>_<step>.result.json`: normalized machine-readable result with:
    - `http_code`
    - `curl_exit_code` (if parseable from curl error output)
    - `policy_decision_hint`
    - `raw_output_file`
