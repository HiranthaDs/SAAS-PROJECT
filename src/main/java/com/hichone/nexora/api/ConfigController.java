package com.hichone.nexora.api;

import java.util.LinkedHashMap;

import com.hichone.nexora.config.SupabaseProperties;
import org.springframework.http.CacheControl;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.ObjectMapper;

@RestController
public class ConfigController {

    private static final MediaType JAVASCRIPT = MediaType.parseMediaType("application/javascript");

    private final SupabaseProperties properties;
    private final ObjectMapper objectMapper;

    public ConfigController(SupabaseProperties properties, ObjectMapper objectMapper) {
        this.properties = properties;
        this.objectMapper = objectMapper;
    }

    @GetMapping(value = "/api/config.js", produces = "application/javascript")
    ResponseEntity<String> publicConfiguration() throws JacksonException {
        var config = new LinkedHashMap<String, Object>();
        config.put("supabaseUrl", properties.getUrl());
        config.put("supabasePublishableKey", properties.getPublishableKey());
        config.put("configured", properties.hasPublicConfiguration());

        String script = "window.__NEXORA_CONFIG__=Object.freeze("
            + objectMapper.writeValueAsString(config) + ");";
        return ResponseEntity.ok()
            .contentType(JAVASCRIPT)
            .cacheControl(CacheControl.noStore())
            .body(script);
    }
}
