package com.hichone.nexora.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "app.supabase")
public class SupabaseProperties {

    private String url = "";
    private String publishableKey = "";
    private String secretKey = "";

    public String getUrl() {
        return url;
    }

    public void setUrl(String url) {
        this.url = valueOrEmpty(url).replaceAll("/+$", "");
    }

    public String getPublishableKey() {
        return publishableKey;
    }

    public void setPublishableKey(String publishableKey) {
        this.publishableKey = valueOrEmpty(publishableKey);
    }

    public String getSecretKey() {
        return secretKey;
    }

    public void setSecretKey(String secretKey) {
        this.secretKey = valueOrEmpty(secretKey);
    }

    public boolean hasPublicConfiguration() {
        return !url.isBlank() && !publishableKey.isBlank();
    }

    public boolean hasServiceConfiguration() {
        return !url.isBlank() && !secretKey.isBlank();
    }

    private static String valueOrEmpty(String value) {
        return value == null ? "" : value.trim();
    }
}
