// herdr-move.mjs — moving a split from the prefix+w picker.
//
// Pure: no terminal, no herdr calls. The picker drops one pane at a time and
// runs `moveArgv` right away (then reloads), so there's no plan to order.
//
//   model = buildModel(state)          snapshot of `connect-herdr.sh state`
//   dest  = {kind: "ws", wsId}         → new tab in that workspace
//         | {kind: "tab", wsId, tabId} → split into that tab
//
// Everything is keyed by herdr ids (wB, wB:t2, wB:p7); labels are display only.

export function buildModel(state) {
    const ws = [...(state.ws ?? [])].sort((a, b) => (a.number ?? 0) - (b.number ?? 0));
    // tab order is `herdr tab list` order (display order): .number is a creation
    // counter that keeps gaps after moves/closes, so it must not drive order
    const tabs = [...(state.tabs ?? [])];
    const workspaces = ws.map((w) => ({
        id: w.workspace_id, label: w.label ?? w.workspace_id, number: w.number,
        focused: !!w.focused, status: w.agent_status ?? "unknown",
        activeTabId: w.active_tab_id ?? null,
    }));
    const wsIds = new Set(workspaces.map((w) => w.id));
    const perWs = new Map();
    const tabList = tabs.filter((t) => wsIds.has(t.workspace_id)).map((t) => {
        const position = (perWs.get(t.workspace_id) ?? 0) + 1;
        perWs.set(t.workspace_id, position);
        return {
            id: t.tab_id, wsId: t.workspace_id, number: t.number, position,
            label: t.label ?? "", status: t.agent_status ?? "unknown",
        };
    });
    const tabIds = new Set(tabList.map((t) => t.id));
    const perTab = new Map();
    const panes = (state.panes ?? []).filter((p) => tabIds.has(p.tab_id)).map((p) => {
        const index = perTab.get(p.tab_id) ?? 0;
        perTab.set(p.tab_id, index + 1);
        return {
            id: p.pane_id, tabId: p.tab_id, wsId: p.workspace_id, index,
            agent: p.agent ?? null, status: p.agent_status ?? "unknown",
            title: p.terminal_title_stripped ?? "", cwd: p.foreground_cwd ?? p.cwd ?? "",
            terminalId: p.terminal_id ?? null, focused: !!p.focused,
        };
    });
    return {
        workspaces, tabs: tabList, panes,
        ws: new Map(workspaces.map((w) => [w.id, w])),
        tab: new Map(tabList.map((t) => [t.id, t])),
        pane: new Map(panes.map((p) => [p.id, p])),
    };
}

export const shortId = (id) => String(id).split(":").pop();

// would dropping paneId on dest change nothing? (its own tab; or a new tab
// when it's already alone in its tab in that workspace)
export function isNoop(model, paneId, dest) {
    const p = model.pane.get(paneId);
    if (!p || !dest) return true;
    if (dest.kind === "tab") return dest.tabId === p.tabId;
    return dest.wsId === p.wsId && model.panes.filter((q) => q.tabId === p.tabId).length === 1;
}

export function moveArgv(paneId, to) {
    if (to.kind === "tab")
        return ["pane", "move", paneId, "--tab", to.tabId, "--split", "right", "--no-focus"];
    return ["pane", "move", paneId, "--new-tab", "--workspace", to.wsId, "--no-focus"];
}
