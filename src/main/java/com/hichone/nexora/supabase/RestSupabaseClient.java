package com.hichone.nexora.supabase;

import java.util.Map;

import com.hichone.nexora.api.ApiException;
import com.hichone.nexora.config.SupabaseProperties;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.ObjectMapper;
import tools.jackson.databind.node.JsonNodeFactory;

@Component
public class RestSupabaseClient implements SupabaseClient {

    private final RestClient restClient;
    private final SupabaseProperties properties;
    private final ObjectMapper objectMapper;

    public RestSupabaseClient(
        RestClient supabaseRestClient,
        SupabaseProperties properties,
        ObjectMapper objectMapper
    ) {
        this.restClient = supabaseRestClient;
        this.properties = properties;
        this.objectMapper = objectMapper;
    }

    @Override
    public void requireServiceConfiguration() {
        if (!properties.hasServiceConfiguration()) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "Account service is not configured.");
        }
    }

    @Override
    public JsonNode getUser(String accessToken) {
        requireServiceConfiguration();
        return exchange(
            HttpMethod.GET,
            "/auth/v1/user",
            null,
            Map.of(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
        );
    }

    @Override
    public JsonNode serviceCall(
        HttpMethod method,
        String path,
        Object body,
        Map<String, String> headers
    ) {
        requireServiceConfiguration();
        return exchange(method, path, body, headers);
    }

    private JsonNode exchange(
        HttpMethod method,
        String path,
        Object body,
        Map<String, String> headers
    ) {
        try {
            RestClient.RequestBodySpec request = restClient.method(method)
                .uri(properties.getUrl() + path)
                .header("apikey", properties.getSecretKey())
                .header(
                    HttpHeaders.AUTHORIZATION,
                    headers.getOrDefault(
                        HttpHeaders.AUTHORIZATION,
                        "Bearer " + properties.getSecretKey()
                    )
                )
                .accept(MediaType.APPLICATION_JSON);

            headers.forEach((name, value) -> {
                if (!HttpHeaders.AUTHORIZATION.equalsIgnoreCase(name)) {
                    request.header(name, value);
                }
            });
            if (body != null) {
                request.contentType(MediaType.APPLICATION_JSON).body(body);
            }

            String responseBody = request.retrieve().body(String.class);
            return parse(responseBody);
        } catch (RestClientResponseException exception) {
            throw new ApiException(exception.getStatusCode(), errorMessage(exception.getResponseBodyAsString()));
        } catch (ResourceAccessException exception) {
            throw new ApiException(HttpStatus.BAD_GATEWAY, "Unable to reach the account service.");
        }
    }

    private JsonNode parse(String body) {
        if (body == null || body.isBlank()) {
            return JsonNodeFactory.instance.objectNode();
        }
        try {
            return objectMapper.readTree(body);
        } catch (Exception exception) {
            throw new ApiException(HttpStatus.BAD_GATEWAY, "Account service returned an invalid response.");
        }
    }

    private String errorMessage(String body) {
        try {
            JsonNode error = objectMapper.readTree(body);
            for (String field : new String[] {"msg", "message", "error_description", "details", "error"}) {
                if (error.path(field).isString() && !error.path(field).stringValue("").isBlank()) {
                    return error.path(field).stringValue("");
                }
            }
        } catch (Exception ignored) {
            // Use the stable fallback below when an upstream proxy returns non-JSON content.
        }
        return "Account service request failed.";
    }
}
