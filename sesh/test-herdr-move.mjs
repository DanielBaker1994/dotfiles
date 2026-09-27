// node --test ~/.dotfiles/sesh/test-herdr-move.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildModel, isNoop, moveArgv, shortId } from "./herdr-move.mjs";

// captured from `connect-herdr.sh state` (trimmed)
const STATE = {
    ws: [
        { workspace_id: "wB", label: ".dotfiles", number: 1, focused: true, active_tab_id: "wB:t2" },
        { workspace_id: "wD", label: "interview_prep", number: 2, active_tab_id: "wD:t1" },
        { workspace_id: "wG", label: "home_server", number: 3, active_tab_id: "wG:t1" },
    ],
    tabs: [
        { tab_id: "wB:t1", workspace_id: "wB", number: 1, label: "1" },
        { tab_id: "wB:t2", workspace_id: "wB", number: 2, label: "○ ⬓ 2" },
        { tab_id: "wD:t1", workspace_id: "wD", number: 1, label: "1" },
        { tab_id: "wG:t1", workspace_id: "wG", number: 1, label: "1" },
    ],
    panes: [
        { pane_id: "wB:p1", tab_id: "wB:t1", workspace_id: "wB", foreground_cwd: "/h/.dotfiles" },
        { pane_id: "wB:p8", tab_id: "wB:t1", workspace_id: "wB", foreground_cwd: "/h/.dotfiles" },
        { pane_id: "wB:p7", tab_id: "wB:t2", workspace_id: "wB", agent: "opencode", agent_status: "idle" },
        { pane_id: "wD:p1", tab_id: "wD:t1", workspace_id: "wD" },
        { pane_id: "wG:p1", tab_id: "wG:t1", workspace_id: "wG" },
    ],
};
const model = buildModel(STATE);
const ws = (wsId) => ({ kind: "ws", wsId });
const tab = (tabId) => ({ kind: "tab", wsId: tabId.split(":")[0], tabId });

test("model keeps ids, pane index within its tab, original workspace", () => {
    assert.deepEqual(model.workspaces.map((w) => w.id), ["wB", "wD", "wG"]);
    assert.equal(model.pane.get("wB:p8").index, 1);
    assert.equal(model.pane.get("wB:p8").tabId, "wB:t1");
    assert.equal(model.pane.get("wG:p1").wsId, "wG");
});

test("dropping on its own tab is a no-op; own workspace only when it's alone", () => {
    assert.equal(isNoop(model, "wB:p7", tab("wB:t2")), true);
    assert.equal(isNoop(model, "wB:p7", ws("wB")), true);   // alone in wB:t2
    assert.equal(isNoop(model, "wB:p8", ws("wB")), false);  // wB:t1 has 2 splits → new tab
    assert.equal(isNoop(model, "wB:p8", tab("wB:t2")), false);
    assert.equal(isNoop(model, "nope", ws("wG")), true);
    assert.equal(isNoop(model, "wB:p7", null), true);
});

test("argv: workspace → new tab, tab → split right, never focus", () => {
    assert.deepEqual(moveArgv("wB:p7", ws("wD")),
        ["pane", "move", "wB:p7", "--new-tab", "--workspace", "wD", "--no-focus"]);
    assert.deepEqual(moveArgv("wG:p1", tab("wB:t1")),
        ["pane", "move", "wG:p1", "--tab", "wB:t1", "--split", "right", "--no-focus"]);
    assert.equal(shortId("wB:p7"), "p7");
});
