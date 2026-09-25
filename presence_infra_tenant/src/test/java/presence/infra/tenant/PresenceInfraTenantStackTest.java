package presence.infra.tenant;

import org.junit.jupiter.api.Test;
import software.amazon.awscdk.App;
import software.amazon.awscdk.assertions.Template;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertEquals;

class PresenceInfraTenantStackTest {

    @Test
    void synthesizesWithNoResourcesYet() {
        App app = new App();
        PresenceInfraTenantStack stack = new PresenceInfraTenantStack(app, "Test");

        Map<String, Map<String, Object>> resources = Template.fromStack(stack).findResources("AWS::*::*");

        assertEquals(Map.of(), resources);
    }
}
