# Tenant infrastructure (`presence_infra_tenant`)

An AWS CDK v2 app in Java in
[presence_infra_tenant/](../presence_infra_tenant): JDK 25, Maven,
`aws-cdk-lib` 2.270.0 and `constructs` 10.8.1. `PresenceInfraTenantApp` creates
one stack, `PresenceInfraTenantStack`, in the account and region of the
active AWS profile (`CDK_DEFAULT_ACCOUNT` / `CDK_DEFAULT_REGION`).

- The stack has no resources yet. It's a scaffold for per-tenant resources.
- [cdk.json](../presence_infra_tenant/cdk.json) runs the app with
  `mvn compile exec:java` and sets the recommended feature flags from
  `cdk init`.
- A unit test checks that the stack synthesizes with no resources.
- Not deployed or bootstrapped yet. The commands are in the module's
  [README](../presence_infra_tenant/README.md).
