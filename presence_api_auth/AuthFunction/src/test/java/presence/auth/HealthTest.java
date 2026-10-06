package presence.auth;

import org.junit.jupiter.api.Test;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.assertEquals;

class HealthTest {

    private static final Instant NOW = Instant.parse("2026-10-05T12:00:00Z");

    private static HealthHandler.Check ok(String name) {
        return new HealthHandler.Check(name, () -> {
        });
    }

    private static HealthHandler.Check failing(String name) {
        return new HealthHandler.Check(name, () -> {
            throw new IllegalStateException("table presence-x is CREATING");
        });
    }

    private static HealthHandler handler(List<HealthHandler.Check> checks) {
        return new HealthHandler(checks, Clock.fixed(NOW, ZoneOffset.UTC), Duration.ofMillis(500));
    }

    @Test
    void everyCheckPassing() {
        var response = handler(List.of(ok("settings"), ok("dynamodb"))).handleRequest(null, null);
        assertEquals(200, response.getStatusCode());
        assertEquals("{\"status\":\"ok\",\"checks\":{\"settings\":\"ok\",\"dynamodb\":\"ok\"}}", response.getBody());
        assertEquals("no-store", response.getHeaders().get("Cache-Control"));
    }

    @Test
    void reportsTheDeployedVersion() {
        var health = new HealthHandler(List.of(ok("settings")), Clock.fixed(NOW, ZoneOffset.UTC),
                Duration.ofMillis(500), "0.6.202610061200");
        var response = health.handleRequest(null, null);
        assertEquals(200, response.getStatusCode());
        assertEquals("{\"status\":\"ok\",\"checks\":{\"settings\":\"ok\"},\"version\":\"0.6.202610061200\"}",
                response.getBody());
        // Failing too, so a broken release still says which it is.
        health = new HealthHandler(List.of(failing("s3")), Clock.fixed(NOW, ZoneOffset.UTC),
                Duration.ofMillis(500), "0.6.202610061200");
        assertEquals("{\"status\":\"fail\",\"checks\":{\"s3\":\"fail\"},\"version\":\"0.6.202610061200\"}",
                health.handleRequest(null, null).getBody());
    }

    @Test
    void oneFailingWithoutSayingWhy() {
        var response = handler(List.of(ok("settings"), failing("dynamodb"), ok("s3"))).handleRequest(null, null);
        assertEquals(503, response.getStatusCode());
        assertEquals("{\"status\":\"fail\",\"checks\":{\"settings\":\"ok\",\"dynamodb\":\"fail\",\"s3\":\"ok\"}}",
                response.getBody());
    }

    @Test
    void aSlowCheckFailsAtTheBudget() {
        var slow = new HealthHandler.Check("google", () -> Thread.sleep(5_000));
        var started = System.nanoTime();
        var response = handler(List.of(ok("settings"), slow)).handleRequest(null, null);
        assertEquals(503, response.getStatusCode());
        assertEquals("{\"status\":\"fail\",\"checks\":{\"settings\":\"ok\",\"google\":\"fail\"}}", response.getBody());
        var took = Duration.ofNanos(System.nanoTime() - started);
        assertEquals(true, took.compareTo(Duration.ofSeconds(2)) < 0, "took " + took);
    }

    @Test
    void reusesAResultForAWhile() {
        var calls = new AtomicInteger();
        var counted = new HealthHandler.Check("dynamodb", calls::incrementAndGet);
        var clock = new MutableClock(NOW);
        var health = new HealthHandler(List.of(counted), clock, Duration.ofMillis(500));
        health.handleRequest(null, null);
        clock.now = NOW.plus(HealthHandler.CACHE_FOR).minusSeconds(1);
        health.handleRequest(null, null);
        assertEquals(1, calls.get());
        clock.now = NOW.plus(HealthHandler.CACHE_FOR);
        health.handleRequest(null, null);
        assertEquals(2, calls.get());
    }

    private static final class MutableClock extends Clock {
        Instant now;

        MutableClock(Instant now) {
            this.now = now;
        }

        @Override
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        @Override
        public Clock withZone(ZoneId zone) {
            return this;
        }

        @Override
        public Instant instant() {
            return now;
        }
    }
}
