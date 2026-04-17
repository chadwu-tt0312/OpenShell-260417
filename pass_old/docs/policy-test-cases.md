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
