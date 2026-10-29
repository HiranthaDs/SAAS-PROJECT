package com.hichone.nexora;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.forwardedUrl;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;

@SpringBootTest(properties = {
    "debug=false",
    "app.supabase.url=https://example.supabase.co",
    "app.supabase.publishable-key=public-test-key",
    "app.supabase.secret-key=server-secret-must-not-leak"
})
@AutoConfigureMockMvc
class WebApplicationTests {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void servesApplicationAndClientRoutes() throws Exception {
        mockMvc.perform(get("/"))
            .andExpect(status().isOk())
            .andExpect(forwardedUrl("index.html"));
        mockMvc.perform(get("/index.html"))
            .andExpect(status().isOk())
            .andExpect(content().string(org.hamcrest.Matchers.containsString("HICH ONE")));
        mockMvc.perform(get("/hotel/example-hotel"))
            .andExpect(status().isOk())
            .andExpect(forwardedUrl("/index.html"));
    }

    @Test
    void exposesOnlyBrowserSafeRuntimeConfiguration() throws Exception {
        mockMvc.perform(get("/api/config.js"))
            .andExpect(status().isOk())
            .andExpect(content().contentTypeCompatibleWith("application/javascript"))
            .andExpect(content().string(org.hamcrest.Matchers.containsString("public-test-key")))
            .andExpect(content().string(org.hamcrest.Matchers.not(
                org.hamcrest.Matchers.containsString("server-secret-must-not-leak")
            )));
    }

    @Test
    void returnsStableValidationErrorsFromJavaApi() throws Exception {
        mockMvc.perform(post("/api/signup")
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                    {"email":"invalid","password":"long-enough","full_name":"Owner"}
                    """))
            .andExpect(status().isBadRequest())
            .andExpect(jsonPath("$.error").value("Enter a valid email address."));
    }

    @Test
    void exposesHealthEndpoint() throws Exception {
        mockMvc.perform(get("/actuator/health"))
            .andExpect(status().isOk())
            .andExpect(jsonPath("$.status").value("UP"));
    }
}
