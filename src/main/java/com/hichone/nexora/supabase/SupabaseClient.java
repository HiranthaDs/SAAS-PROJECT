package com.hichone.nexora.supabase;

import java.util.Map;

import org.springframework.http.HttpMethod;
import tools.jackson.databind.JsonNode;

public interface SupabaseClient {

    void requireServiceConfiguration();

    JsonNode getUser(String accessToken);

    JsonNode serviceCall(HttpMethod method, String path, Object body, Map<String, String> headers);
}
