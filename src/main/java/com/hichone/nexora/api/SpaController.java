package com.hichone.nexora.api;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

@Controller
public class SpaController {

    @GetMapping({
        "/book/{slug}",
        "/hotel/{slug}",
        "/medical/{slug}",
        "/staff/{slug}"
    })
    String forwardClientRoute() {
        return "forward:/index.html";
    }
}
