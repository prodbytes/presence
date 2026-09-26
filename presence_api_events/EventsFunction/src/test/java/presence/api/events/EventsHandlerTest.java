package presence.api.events;

import com.amazonaws.services.lambda.runtime.events.APIGatewayProxyRequestEvent;
import com.amazonaws.services.lambda.runtime.events.APIGatewayProxyResponseEvent;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class EventsHandlerTest {

    @Test
    void listsEventsAsJson() {
        APIGatewayProxyResponseEvent response =
                new EventsHandler().handleRequest(new APIGatewayProxyRequestEvent(), null);

        assertEquals(200, response.getStatusCode());
        assertEquals("application/json", response.getHeaders().get("Content-Type"));
        assertEquals("{\"events\":[]}", response.getBody());
    }
}
