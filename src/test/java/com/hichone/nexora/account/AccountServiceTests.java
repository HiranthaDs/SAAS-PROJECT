package com.hichone.nexora.account;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.util.Map;

import com.hichone.nexora.api.ApiException;
import com.hichone.nexora.supabase.SupabaseClient;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.HttpMethod;
import tools.jackson.databind.ObjectMapper;

@ExtendWith(MockitoExtension.class)
class AccountServiceTests {

    @Mock
    private SupabaseClient supabase;

    private final ObjectMapper objectMapper = new ObjectMapper();
    private AccountService service;

    @BeforeEach
    void setUp() {
        service = new AccountService(supabase);
    }

    @Test
    void rejectsInvalidSignupBeforeCallingSupabase() {
        var request = new SignupRequest("not-an-email", "long-enough", "Owner", "Company");

        assertThatThrownBy(() -> service.createWorkspace(request))
            .isInstanceOf(ApiException.class)
            .hasMessage("Enter a valid email address.");
        verify(supabase, never()).requireServiceConfiguration();
    }

    @Test
    void createsAndPromotesWorkspaceOwner() throws Exception {
        when(supabase.serviceCall(
            eq(HttpMethod.POST), eq("/auth/v1/admin/users"), any(), eq(Map.of())
        )).thenReturn(objectMapper.readTree("{\"id\":\"8ec7c670-f32b-4afb-807c-2d65ee119977\"}"));
        when(supabase.serviceCall(
            eq(HttpMethod.PATCH),
            eq("/rest/v1/profiles?id=eq.8ec7c670-f32b-4afb-807c-2d65ee119977"),
            any(),
            eq(Map.of("Prefer", "return=minimal"))
        )).thenReturn(objectMapper.createObjectNode());

        Map<String, Object> result = service.createWorkspace(
            new SignupRequest("OWNER@EXAMPLE.COM", "long-enough", "Owner", "Company")
        );

        assertThat(result).containsEntry("created", true)
            .containsEntry("user_id", "8ec7c670-f32b-4afb-807c-2d65ee119977");
        verify(supabase).requireServiceConfiguration();
    }
}
