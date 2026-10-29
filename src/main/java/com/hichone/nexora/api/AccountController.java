package com.hichone.nexora.api;

import java.util.Map;

import com.hichone.nexora.account.AccountService;
import com.hichone.nexora.account.ManagedAccountRequest;
import com.hichone.nexora.account.SignupRequest;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api")
public class AccountController {

    private final AccountService accountService;

    public AccountController(AccountService accountService) {
        this.accountService = accountService;
    }

    @PostMapping("/signup")
    ResponseEntity<Map<String, Object>> signup(@RequestBody SignupRequest request) {
        return ResponseEntity.status(HttpStatus.CREATED)
            .body(accountService.createWorkspace(request));
    }

    @PostMapping("/admin/accounts")
    ResponseEntity<Map<String, Object>> createManagedAccount(
        @RequestHeader(name = "Authorization", required = false, defaultValue = "") String authorization,
        @RequestBody ManagedAccountRequest request
    ) {
        return ResponseEntity.status(HttpStatus.CREATED)
            .body(accountService.createManagedAccount(authorization, request));
    }

    @PatchMapping("/admin/accounts/{userId}")
    Map<String, Object> updateManagedAccount(
        @RequestHeader(name = "Authorization", required = false, defaultValue = "") String authorization,
        @PathVariable String userId,
        @RequestBody ManagedAccountRequest request
    ) {
        return accountService.updateManagedAccount(authorization, userId, request);
    }
}
