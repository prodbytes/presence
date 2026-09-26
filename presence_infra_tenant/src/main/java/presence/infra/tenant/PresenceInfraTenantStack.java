package presence.infra.tenant;

import software.amazon.awscdk.Stack;
import software.amazon.awscdk.StackProps;
import software.constructs.Construct;

/** Per-tenant infrastructure for Presence. Empty until resources are added. */
public class PresenceInfraTenantStack extends Stack {

    public PresenceInfraTenantStack(final Construct scope, final String id) {
        this(scope, id, null);
    }

    public PresenceInfraTenantStack(final Construct scope, final String id, final StackProps props) {
        super(scope, id, props);
    }
}
