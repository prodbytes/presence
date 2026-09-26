package presence.infra.tenant;

import software.amazon.awscdk.App;
import software.amazon.awscdk.Environment;
import software.amazon.awscdk.StackProps;

public final class PresenceInfraTenantApp {

    public static void main(final String[] args) {
        App app = new App();

        // Deploy to the account and region of the active AWS CLI profile.
        new PresenceInfraTenantStack(app, "PresenceInfraTenantStack", StackProps.builder()
                .env(Environment.builder()
                        .account(System.getenv("CDK_DEFAULT_ACCOUNT"))
                        .region(System.getenv("CDK_DEFAULT_REGION"))
                        .build())
                .build());

        app.synth();
    }
}
