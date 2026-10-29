package com.hichone.nexora.account;

import com.fasterxml.jackson.annotation.JsonProperty;

public record SignupRequest(
    String email,
    String password,
    @JsonProperty("full_name") String fullName,
    @JsonProperty("company_name") String companyName
) {
}
