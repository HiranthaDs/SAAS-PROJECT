package com.hichone.nexora.supabase;

import static org.assertj.core.api.Assertions.assertThat;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

import com.hichone.nexora.config.SupabaseProperties;
import com.sun.net.httpserver.Headers;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpMethod;
import org.springframework.web.client.RestClient;
import tools.jackson.databind.ObjectMapper;

class RestSupabaseClientTests {

    private HttpServer server;
    private volatile Headers receivedHeaders;
    private RestSupabaseClient client;

    @BeforeEach
    void setUp() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", this::respond);
        server.start();

        var properties = new SupabaseProperties();
        properties.setUrl("http://127.0.0.1:" + server.getAddress().getPort());
        properties.setPublishableKey("public-key");
        properties.setSecretKey("service-secret");
        client = new RestSupabaseClient(RestClient.create(), properties, new ObjectMapper());
    }

    @AfterEach
    void tearDown() {
        server.stop(0);
    }

    @Test
    void sendsUserTokenOnlyWhenValidatingSession() {
        client.getUser("user-access-token");

        assertThat(receivedHeaders.get("Authorization"))
            .containsExactly("Bearer user-access-token");
        assertThat(receivedHeaders.getFirst("apikey")).isEqualTo("service-secret");
    }

    @Test
    void sendsServiceTokenForAdministrativeRequests() {
        client.serviceCall(HttpMethod.GET, "/rest/v1/profiles", null, Map.of());

        assertThat(receivedHeaders.get("Authorization"))
            .containsExactly("Bearer service-secret");
        assertThat(receivedHeaders.getFirst("apikey")).isEqualTo("service-secret");
    }

    private void respond(HttpExchange exchange) throws IOException {
        receivedHeaders = exchange.getRequestHeaders();
        byte[] response = "{\"id\":\"8ec7c670-f32b-4afb-807c-2d65ee119977\"}"
            .getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().put("Content-Type", List.of("application/json"));
        exchange.sendResponseHeaders(200, response.length);
        exchange.getResponseBody().write(response);
        exchange.close();
    }
}
