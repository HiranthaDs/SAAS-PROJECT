package com.hichone.nexora.account;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

import com.hichone.nexora.api.ApiException;
import com.hichone.nexora.supabase.SupabaseClient;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.util.UriUtils;
import tools.jackson.databind.JsonNode;

@Service
public class AccountService {

    private static final Pattern EMAIL = Pattern.compile("^\\S+@\\S+\\.\\S+$");
    private static final Pattern UUID = Pattern.compile("^[0-9a-f-]{36}$", Pattern.CASE_INSENSITIVE);
    private static final Set<String> ROLES = Set.of("viewer", "member", "manager", "admin");
    private static final Set<String> STATUSES = Set.of("active", "suspended");
    private static final List<String> PERMISSION_KEYS = List.of(
        "salon_view", "salon_create", "salon_move", "salon_approve", "salon_allocate",
        "hotel_view", "hotel_bookings", "hotel_manage",
        "medical_view", "medical_issue", "medical_call", "medical_manage",
        "customers_view", "sales_view", "settings_view"
    );
    private static final Map<String, String> DEPARTMENTS = Map.ofEntries(
        Map.entry("clothing_fashion", "Fashion"),
        Map.entry("restaurant", "Restaurant"),
        Map.entry("hotel", "Hospitality"),
        Map.entry("construction", "Construction"),
        Map.entry("real_estate", "Property"),
        Map.entry("education", "Education"),
        Map.entry("healthcare_clinic", "Healthcare"),
        Map.entry("logistics", "Logistics"),
        Map.entry("manufacturing_business", "Production"),
        Map.entry("agriculture", "Agriculture"),
        Map.entry("automotive", "Automotive"),
        Map.entry("retail_grocery", "Retail"),
        Map.entry("pharmacy", "Pharmacy"),
        Map.entry("salon", "Salon")
    );

    private final SupabaseClient supabase;

    public AccountService(SupabaseClient supabase) {
        this.supabase = supabase;
    }

    public Map<String, Object> createWorkspace(SignupRequest request) {
        String email = normalizedEmail(request.email());
        String password = value(request.password());
        String fullName = value(request.fullName()).trim();
        String companyName = value(request.companyName()).trim();
        if (companyName.isBlank()) {
            companyName = fullName + "'s Workspace";
        }

        require(EMAIL.matcher(email).matches(), "Enter a valid email address.");
        require(password.length() >= 8, "Password must contain at least 8 characters.");
        require(!fullName.isBlank(), "Your name is required.");
        supabase.requireServiceConfiguration();

        JsonNode created;
        try {
            created = call(HttpMethod.POST, "/auth/v1/admin/users", Map.of(
                "email", email,
                "password", password,
                "email_confirm", true,
                "user_metadata", Map.of(
                    "full_name", fullName,
                    "company_name", companyName,
                    "provisioning_kind", "workspace_owner"
                )
            ));
        } catch (ApiException exception) {
            throw remapDuplicateAccount(exception);
        }

        String userId = requiredText(created, "id", "Account service did not return a user ID.");
        try {
            call(HttpMethod.PATCH, "/rest/v1/profiles?id=eq." + query(userId),
                Map.of("platform_role", "super_admin"), minimal());
        } catch (ApiException exception) {
            safeCall(HttpMethod.DELETE, "/auth/v1/admin/users/" + query(userId), null);
            throw exception;
        }
        return Map.of("created", true, "user_id", userId);
    }

    public Map<String, Object> createManagedAccount(
        String authorization,
        ManagedAccountRequest request
    ) {
        String orgId = value(request.orgId());
        JsonNode actor = requireSuperAdmin(authorization, orgId);
        String locationId = value(request.locationId());
        String email = normalizedEmail(request.email());
        String password = value(request.password());
        String fullName = value(request.fullName()).trim();
        String title = value(request.title()).trim();
        String requestedRole = value(request.role());
        String role = ROLES.contains(requestedRole) ? requestedRole : "member";

        requireUuid(orgId, "Choose a valid workspace.");
        requireUuid(locationId, "Choose a valid business location.");
        require(EMAIL.matcher(email).matches(), "Enter a valid email address.");
        require(password.length() >= 10, "Temporary password must contain at least 10 characters.");
        require(!fullName.isBlank(), "Full name is required.");

        JsonNode organization = first(call(HttpMethod.GET,
            "/rest/v1/organizations?id=eq." + query(orgId) + "&select=id,name,business_type"));
        if (organization == null) {
            throw new ApiException(HttpStatus.NOT_FOUND, "Workspace not found.");
        }
        JsonNode location = first(call(HttpMethod.GET,
            "/rest/v1/salon_locations?id=eq." + query(locationId)
                + "&org_id=eq." + query(orgId)
                + "&active=eq.true&select=id,name,employee_login_slug"));
        if (location == null) {
            throw new ApiException(HttpStatus.NOT_FOUND, "Business location not found or inactive.");
        }

        String userId = "";
        try {
            JsonNode created = call(HttpMethod.POST, "/auth/v1/admin/users", Map.of(
                "email", email,
                "password", password,
                "email_confirm", true,
                "user_metadata", Map.of(
                    "full_name", fullName,
                    "company_name", fullName + " setup",
                    "provisioning_kind", "employee"
                )
            ));
            userId = requiredText(created, "id", "Account service did not return a user ID.");

            JsonNode automaticMemberships = call(HttpMethod.GET,
                "/rest/v1/memberships?user_id=eq." + query(userId) + "&select=org_id");
            if (automaticMemberships.isArray()) {
                for (JsonNode membership : automaticMemberships) {
                    String automaticOrgId = membership.path("org_id").stringValue("");
                    if (!automaticOrgId.isBlank() && !automaticOrgId.equals(orgId)) {
                        call(HttpMethod.DELETE,
                            "/rest/v1/organizations?id=eq." + query(automaticOrgId)
                                + "&owner_id=eq." + query(userId), null, minimal());
                    }
                }
            }

            call(HttpMethod.PATCH, "/rest/v1/profiles?id=eq." + query(userId), mapOfNullable(
                "full_name", fullName,
                "email", email,
                "must_change_password", true
            ), minimal());
            call(HttpMethod.POST, "/rest/v1/memberships?on_conflict=org_id,user_id", Map.of(
                "org_id", orgId,
                "user_id", userId,
                "role", role,
                "status", "active"
            ), upsert());
            call(HttpMethod.POST, "/rest/v1/organization_user_access?on_conflict=org_id,user_id",
                mapOfNullable(
                    "org_id", orgId,
                    "user_id", userId,
                    "location_id", locationId,
                    "title", title.isBlank() ? null : title,
                    "permissions", cleanPermissions(request.permissions()),
                    "created_by", actor.path("id").stringValue("")
                ), upsert());

            String businessType = organization.path("business_type").stringValue("");
            call(HttpMethod.POST, "/rest/v1/employees", mapOfNullable(
                "org_id", orgId,
                "location_id", locationId,
                "user_id", userId,
                "name", fullName,
                "email", email,
                "role_title", title.isBlank() ? "Workspace user" : title,
                "department", DEPARTMENTS.getOrDefault(businessType, "Operations"),
                "employment_status", "active",
                "bookable_for_appointments", "salon".equals(businessType)
            ), minimal());
            audit(orgId, actor.path("id").stringValue(""), "account.created", userId, mapOfNullable(
                "account_email", email,
                "full_name", fullName,
                "role", role,
                "title", title,
                "location_id", locationId,
                "location_name", location.path("name").stringValue("")
            ));

            return mapOfNullable(
                "created", true,
                "user_id", userId,
                "location_id", locationId,
                "employee_login_slug", location.path("employee_login_slug").stringValue("")
            );
        } catch (ApiException exception) {
            if (!userId.isBlank()) {
                safeCall(HttpMethod.DELETE,
                    "/rest/v1/employees?user_id=eq." + query(userId), null, minimal());
                safeCall(HttpMethod.DELETE, "/auth/v1/admin/users/" + query(userId), null);
            }
            throw remapDuplicateAccount(exception);
        }
    }

    public Map<String, Object> updateManagedAccount(
        String authorization,
        String userId,
        ManagedAccountRequest request
    ) {
        String orgId = value(request.orgId());
        JsonNode actor = requireSuperAdmin(authorization, orgId);
        requireUuid(userId, "Choose a valid workspace account.");

        JsonNode membership = first(call(HttpMethod.GET,
            "/rest/v1/memberships?org_id=eq." + query(orgId)
                + "&user_id=eq." + query(userId) + "&select=user_id"));
        if (membership == null) {
            throw new ApiException(HttpStatus.NOT_FOUND, "Workspace account not found.");
        }

        if ("reset_password".equals(request.action())) {
            String password = value(request.password());
            require(password.length() >= 10,
                "Temporary password must contain at least 10 characters.");
            call(HttpMethod.PUT, "/auth/v1/admin/users/" + query(userId),
                Map.of("password", password));
            call(HttpMethod.PATCH, "/rest/v1/profiles?id=eq." + query(userId),
                Map.of("must_change_password", true), minimal());
            audit(orgId, actor.path("id").stringValue(""),
                "account.temporary_password_reset", userId, Map.of());
            return Map.of("updated", true);
        }

        String locationId = value(request.locationId());
        requireUuid(locationId, "Choose a valid business location.");
        JsonNode location = first(call(HttpMethod.GET,
            "/rest/v1/salon_locations?id=eq." + query(locationId)
                + "&org_id=eq." + query(orgId)
                + "&active=eq.true&select=id,name"));
        if (location == null) {
            throw new ApiException(HttpStatus.NOT_FOUND, "Business location not found or inactive.");
        }

        String requestedRole = value(request.role());
        String requestedStatus = value(request.status());
        String role = ROLES.contains(requestedRole) ? requestedRole : "member";
        String status = STATUSES.contains(requestedStatus) ? requestedStatus : "active";
        String actorId = actor.path("id").stringValue("");
        if (actorId.equals(userId) && "suspended".equals(status)) {
            throw new ApiException(HttpStatus.BAD_REQUEST,
                "You cannot suspend your own super-admin account.");
        }
        String title = value(request.title()).trim();
        Map<String, Boolean> permissions = cleanPermissions(request.permissions());

        call(HttpMethod.PATCH,
            "/rest/v1/memberships?org_id=eq." + query(orgId) + "&user_id=eq." + query(userId),
            Map.of("role", role, "status", status), minimal());
        call(HttpMethod.POST, "/rest/v1/organization_user_access?on_conflict=org_id,user_id",
            mapOfNullable(
                "org_id", orgId,
                "user_id", userId,
                "location_id", locationId,
                "title", title.isBlank() ? null : title,
                "permissions", permissions,
                "created_by", actorId
            ), upsert());
        call(HttpMethod.PATCH,
            "/rest/v1/employees?org_id=eq." + query(orgId) + "&user_id=eq." + query(userId),
            Map.of(
                "location_id", locationId,
                "role_title", title.isBlank() ? "Workspace user" : title,
                "employment_status", "active".equals(status) ? "active" : "inactive"
            ), minimal());
        audit(orgId, actorId, "account.permissions_updated", userId, mapOfNullable(
            "role", role,
            "status", status,
            "title", title,
            "location_id", locationId,
            "location_name", location.path("name").stringValue(""),
            "permissions", permissions
        ));
        return Map.of("updated", true);
    }

    private JsonNode requireSuperAdmin(String authorization, String orgId) {
        supabase.requireServiceConfiguration();
        String token = value(authorization).replaceFirst("(?i)^Bearer\\s+", "").trim();
        if (token.isBlank()) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "Sign in is required.");
        }

        JsonNode user;
        try {
            user = supabase.getUser(token);
        } catch (ApiException exception) {
            if (exception.getStatus().is4xxClientError()) {
                throw new ApiException(HttpStatus.UNAUTHORIZED,
                    "Your session is invalid or expired.");
            }
            throw exception;
        }
        String actorId = user.path("id").stringValue("");
        if (actorId.isBlank()) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "Your session is invalid or expired.");
        }

        JsonNode profile = first(call(HttpMethod.GET,
            "/rest/v1/profiles?id=eq." + query(actorId) + "&select=platform_role"));
        if (profile == null) {
            throw new ApiException(HttpStatus.FORBIDDEN,
                "Unable to verify administrator access.");
        }
        String platformRole = profile.path("platform_role").stringValue("");
        if ("system_admin".equals(platformRole)) {
            return user;
        }
        if (!"super_admin".equals(platformRole)) {
            throw new ApiException(HttpStatus.FORBIDDEN,
                "Only a workspace super administrator can manage accounts.");
        }

        JsonNode ownership = first(call(HttpMethod.GET,
            "/rest/v1/memberships?org_id=eq." + query(orgId)
                + "&user_id=eq." + query(actorId)
                + "&role=eq.owner&status=eq.active"
                + "&select=role,status,organizations(account_status)"));
        if (ownership == null
            || !"active".equals(ownership.path("organizations").path("account_status").stringValue(""))) {
            throw new ApiException(HttpStatus.FORBIDDEN,
                "You can manage accounts only in your own active workspace.");
        }
        return user;
    }

    private void audit(
        String orgId,
        String actorId,
        String action,
        String userId,
        Map<String, ?> metadata
    ) {
        call(HttpMethod.POST, "/rest/v1/activity_log", Map.of(
            "org_id", orgId,
            "actor_id", actorId,
            "action", action,
            "entity_type", "account",
            "entity_id", userId,
            "metadata", metadata
        ), minimal());
    }

    private Map<String, Boolean> cleanPermissions(Map<String, Object> requested) {
        Map<String, Boolean> result = new LinkedHashMap<>();
        for (String key : PERMISSION_KEYS) {
            result.put(key, requested != null && Boolean.TRUE.equals(requested.get(key)));
        }
        return result;
    }

    private JsonNode call(HttpMethod method, String path) {
        return call(method, path, null, Map.of());
    }

    private JsonNode call(HttpMethod method, String path, Object body) {
        return call(method, path, body, Map.of());
    }

    private JsonNode call(
        HttpMethod method,
        String path,
        Object body,
        Map<String, String> headers
    ) {
        return supabase.serviceCall(method, path, body, headers);
    }

    private void safeCall(HttpMethod method, String path, Object body) {
        safeCall(method, path, body, Map.of());
    }

    private void safeCall(
        HttpMethod method,
        String path,
        Object body,
        Map<String, String> headers
    ) {
        try {
            call(method, path, body, headers);
        } catch (ApiException ignored) {
            // Cleanup is best effort; the original provisioning error is more useful to the caller.
        }
    }

    private static Map<String, String> minimal() {
        return Map.of("Prefer", "return=minimal");
    }

    private static Map<String, String> upsert() {
        return Map.of("Prefer", "resolution=merge-duplicates,return=minimal");
    }

    private static JsonNode first(JsonNode node) {
        return node != null && node.isArray() && !node.isEmpty() ? node.get(0) : null;
    }

    private static String requiredText(JsonNode node, String field, String message) {
        String result = node.path(field).stringValue("");
        if (result.isBlank()) {
            throw new ApiException(HttpStatus.BAD_GATEWAY, message);
        }
        return result;
    }

    private static String query(String value) {
        return UriUtils.encodeQueryParam(value, StandardCharsets.UTF_8);
    }

    private static String normalizedEmail(String email) {
        return value(email).trim().toLowerCase(Locale.ROOT);
    }

    private static String value(String value) {
        return value == null ? "" : value;
    }

    private static void requireUuid(String value, String message) {
        require(UUID.matcher(value).matches(), message);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new ApiException(HttpStatus.BAD_REQUEST, message);
        }
    }

    private static ApiException remapDuplicateAccount(ApiException exception) {
        if (exception.getStatus().value() == 422) {
            return new ApiException(HttpStatus.CONFLICT, exception.getMessage());
        }
        return exception;
    }

    private static Map<String, Object> mapOfNullable(Object... values) {
        Map<String, Object> result = new LinkedHashMap<>();
        for (int index = 0; index < values.length; index += 2) {
            result.put((String) values[index], values[index + 1]);
        }
        return result;
    }
}
