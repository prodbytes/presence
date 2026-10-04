# presence_sh

https://sh.presence.nu01.com: the install script,
[scripts/install.sh](../scripts/install.sh), served at every path, so

```sh
curl -fsSL https://sh.presence.nu01.com | sh
```

downloads and runs the right Presence app (see
[specs/install-script.md](../specs/install-script.md)).

[template.yaml](template.yaml), stack `presence-sh` in `us-east-1`:

- an **ACM certificate** for `sh.presence.nu01.com`, DNS-validated in the
  `nu01.com` zone (in us-east-1, where CloudFront needs it);
- a private, encrypted **S3 bucket** that only the distribution can read
  (origin access control);
- a **CloudFront distribution** (HTTPS only, plain http refused with 403;
  TLS 1.2+; HTTP/2 and 3; AWS's managed security-headers policy) whose
  viewer-request function maps every path to `/install.sh`;
- Route 53 **A/AAAA aliases** for `sh.presence.nu01.com`.

## Deploying

```sh
bash scripts/deploy-sh.sh   # needs HOSTED_ZONE_ID (environment or .env)
```

It deploys the stack, uploads `scripts/install.sh` as `text/plain` with a
5-minute `Cache-Control`, invalidates the cache, and checks that `/` and
`/install.sh` serve the script byte for byte and that plain http is
refused. The [Deploy workflow](../.github/workflows/deploy.yml) runs it on
every `*GA` tag, after the site deploy, so the live script matches the GA.
