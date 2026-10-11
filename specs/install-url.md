# Install URL

**https://sh.presence.nu01.com** serves the
[install script](install-script.md) at every path, so
`curl -fsSL https://sh.presence.nu01.com | sh` runs it, except
**https://sh.presence.nu01.com/streamer**, which serves the [streamer's
install script](install-script.md#streamer):
`curl -fsSL https://sh.presence.nu01.com/streamer | sh -s -- <profile ID>`.

- **Infrastructure:** [presence_sh/template.yaml](../presence_sh/template.yaml),
  stack `presence-sh` (us-east-1): an ACM certificate for
  `sh.presence.nu01.com` (DNS-validated in the `nu01.com` zone), a private
  encrypted S3 bucket readable only by the distribution (OAC), a CloudFront
  distribution, and Route 53 A/AAAA aliases. The certificate and
  distribution carry the tag `presence:stage=prod` (the template's
  `Stage`, which only allows `prod`): the production deploy role may
  change only distributions and certificates with that tag (see
  [Production deploy](deploy.md#github-access)).
- **Distribution:** a viewer-request CloudFront Function maps `/streamer`,
  `/streamer/` and `/streamer.sh` to `/streamer.sh`, and every other URI to
  `/install.sh`. HTTPS only: plain http gets 403, not a redirect, so
  `curl http://… | sh` fails instead of running a script fetched in the
  clear. TLS 1.2+, HTTP/2 and 3, AWS's managed security-headers policy.
- **Content:** `install.sh` (`scripts/install.sh`) and `streamer.sh`
  (`scripts/install-streamer.sh`), uploaded as `text/plain; charset=utf-8`
  (a browser shows them) with `Cache-Control: public, max-age=300`.
- **Deploy:** [scripts/deploy-sh.sh](../scripts/deploy-sh.sh) deploys the
  stack, uploads both scripts, invalidates `/*`, and checks that `/` and
  `/install.sh` return `install.sh`, and `/streamer` and `/streamer.sh`
  `install-streamer.sh`, byte for byte (retrying while DNS propagates), and
  that http answers 403. The
  [Deploy workflow](../.github/workflows/deploy.yml) runs it after
  `scripts/deploy.sh` on every `*GA` tag, with the `presence-github-deploy`
  role: its `presence-*` stack, bucket and function names cover it, its
  records are under `*.presence.nu01.com`, and its distribution and
  certificate are tagged `prod`. The RC role can't change its stack, bucket,
  distribution or certificate (its origin access control is another
  matter: see [Stage separation](deploy.md#stage-separation)).

## Known limitations

- The scripts change only on a GA deploy (or a hand-run
  `scripts/deploy-sh.sh`), so a merge to `main` isn't live until then; the
  raw GitHub URLs on `main` are always current.
- There's no RC copy: release candidates share the GA script (run one with
  `PRESENCE_TAG=<rc tag>`).
