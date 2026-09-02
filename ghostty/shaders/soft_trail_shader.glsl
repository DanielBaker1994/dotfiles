// Subtle cursor motion trail for Ghostty — flash.nvim-inspired.
// A soft, smooth comet-like trail between the previous and current cursor
// positions. No jaggedness, no forks, no flicker: just a gentle warm fade.

// -- CONFIGURATION --
const vec3 TRAIL_COLOR = vec3(1.00, 1.00, 1.00); // soft white trail
const float DURATION = 0.22;              // how long the trail lingers, in seconds
const float THRESHOLD_MIN_DISTANCE = 1.2; // cursor widths of travel before showing
const float CORE_WIDTH = 1.3;             // trail core, in pixels
const float GLOW_WIDTH = 5.5;             // wide soft glow falloff, in pixels

float segmentDistance(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    float denom = max(dot(ab, ab), 0.0000001);
    float t = clamp(dot(p - a, ab) / denom, 0.0, 1.0);
    return length(p - (a + ab * t));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 terminal = texture(iChannel0, uv);
    fragColor = terminal;

    vec2 currentCenter = iCurrentCursor.xy
        + vec2(iCurrentCursor.z * 0.5, -iCurrentCursor.w * 0.5);
    vec2 previousCenter = iPreviousCursor.xy
        + vec2(iPreviousCursor.z * 0.5, -iPreviousCursor.w * 0.5);
    float travel = length(currentCenter - previousCenter);
    float minimumTravel = iCurrentCursor.z * THRESHOLD_MIN_DISTANCE;

    float age = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    if (travel > minimumTravel && age < 1.0) {
        float dist = segmentDistance(fragCoord, previousCenter, currentCenter);

        // Gentle cubic ease-out: brightest right after the jump, then melts away.
        float fade = 1.0 - age;
        fade = fade * fade * fade;

        // Soft core plus a wide, dim glow. No hard edges.
        float pixel = max(fwidth(dist), 0.6);
        float core = 1.0 - smoothstep(CORE_WIDTH, CORE_WIDTH + pixel, dist);
        float glow = exp(-dist * dist / (GLOW_WIDTH * GLOW_WIDTH));

        float amount = max(core, glow * 0.14) * fade * 0.14;
        fragColor.rgb = mix(fragColor.rgb, TRAIL_COLOR, clamp(amount, 0.0, 1.0));

        // Keep the real cursor crisp on top.
        vec2 cursorMin = vec2(iCurrentCursor.x, iCurrentCursor.y - iCurrentCursor.w);
        vec2 cursorMax = vec2(iCurrentCursor.x + iCurrentCursor.z, iCurrentCursor.y);
        float insideCursor = step(cursorMin.x, fragCoord.x)
            * step(cursorMin.y, fragCoord.y)
            * step(fragCoord.x, cursorMax.x)
            * step(fragCoord.y, cursorMax.y);
        fragColor = mix(fragColor, terminal, insideCursor);
    }
}