# presence_infra_tenant

Per-tenant infrastructure for Presence, as an
[AWS CDK](https://docs.aws.amazon.com/cdk/v2/guide/home.html) v2 app in Java
(JDK 25, `aws-cdk-lib` 2.270.0). It defines one stack,
`PresenceInfraTenantStack`, which has no resources yet.

| Path | Holds |
|------|-------|
| [cdk.json](cdk.json) | Tells the CDK CLI to run the app with Maven |
| [pom.xml](pom.xml) | Maven build: CDK and constructs libraries, JUnit |
| [PresenceInfraTenantApp.java](src/main/java/presence/infra/tenant/PresenceInfraTenantApp.java) | Entry point: creates the stack for the active AWS profile's account and region |
| [PresenceInfraTenantStack.java](src/main/java/presence/infra/tenant/PresenceInfraTenantStack.java) | The stack; add tenant resources here |

## Requirements

- JDK 25 and Maven 3.9+ (provided by devbox: `devbox shell`)
- Node.js, for the CDK CLI (`npx aws-cdk`, or `npm install -g aws-cdk`)

## Commands

Run from this folder:

```bash
mvn test              # unit tests
npx aws-cdk synth     # print the CloudFormation template
npx aws-cdk diff      # compare with the deployed stack
npx aws-cdk bootstrap # once per account and region
npx aws-cdk deploy
```
