package com.hichone.nexora.account;

import java.util.Map;

import com.fasterxml.jackson.annotation.JsonProperty;

public record ManagedAccountRequest(
    @JsonProperty("org_id") String orgId,
    @JsonProperty("location_id") String locationId,
    String email,
    String password,
    @JsonProperty("full_name") String fullName,
    String title,
    String role,
    String status,
    String action,
    Map<String, Object> permissions
) {
}
