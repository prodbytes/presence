# Install URL

**https://sh.presence.nu01.com** serves the
[install script](install-script.md) at every path, so
`curl -fsSL https://sh.presence.nu01.com | sh` runs it.

- **Infrastructure:** [presence_sh/template.yaml](../presence_sh/template.yaml),
  stack `presence-sh` (us-east-1): an ACM certificate for
  `sh.presence.nu01.com` (DNS-validated in the `nu01.com` zone), a private
  encrypted S3 bucket readable only by the distribution (OAC), a CloudFront
  distribution, and Route 53 A/AAAA aliases.
- **Distribution:** a viewer-request CloudFront Function maps every URI to
  `/install.sh`. HTTPS only: plain http gets 403, not a redirect, so
  `curl http://… | sh` fails instead of running a script fetched in the
  clear. TLS 1.2+, HTTP/2 and 3, AWS's managed security-headers policy.
- **Content:** `install.sh`, uploaded as `text/plain; charset=utf-8` (a
  browser shows it) with `Cache-Control: public, max-age=300`.
- **Deploy:** [scripts/deploy-sh.sh](../scripts/deploy-sh.sh) deploys the
  stack, uploads the script, invalidates `/*`, and checks that `/` and
  `/install.sh` return the script byte for byte (retrying while DNS
  propagates) and that http answers 403. The
  [Deploy workflow](../.github/workflows/deploy.yml) runs it after
  `scripts/deploy.sh` on every `*GA` tag, with the `presence-github-deploy`
  role (its `presence-*` stack and bucket scope already covers it).

## Known limitations

- The script changes only on a GA deploy (or a hand-run
  `scripts/deploy-sh.sh`), so a merge to `main` isn't live until then; the
  raw GitHub URL on `main` is always current.
- There's no RC copy: release candidates share the GA script (run one with
  `PRESENCE_TAG=<rc tag>`).
