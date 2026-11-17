// The one fixture behind the site's widget pictures (scripts/site-widgets.sh): the demo machine's
// agents (HerdrKit DemoScript: "Cache product images" on buildbox, the orders migration on studio…)
// as the app would hand them to the widgets and the Live Activity. Keep it in step with the demo.
import Foundation

enum SiteWidgetFixture {
    static let rows: [BergrActivityAttributes.Row] = [
        .init(kind: "codex", title: "Where should product images…", status: "Cache product images", machine: "buildbox",
              needsYou: true, host: "b", address: "t12"),
        .init(kind: "claude", title: "Run the database migration?", status: "Add order totals endpoint", machine: "studio",
              needsYou: true, host: "s", address: "t3"),
        .init(kind: "codex", title: "Upgrade Postgres to 18", status: "Running pg_upgrade checks", machine: "buildbox",
              needsYou: false, host: "b", address: "t11"),
    ]
    static let liveActivity = BergrActivityAttributes.ContentState(needsYou: 2, working: 1, done: 1, rows: rows)
    static let agents = AgentsSnapshot(needsYou: 2, working: 1, done: 1, rows: rows, updated: .now, agents: [
        .init(state: "needsYou", name: "Cache product images", machine: "buildbox",
              lastLine: "Where should product images be cached?", host: "b", address: "t12"),
        .init(state: "needsYou", name: "Add order totals endpoint", machine: "studio",
              lastLine: "Run the database migration?", host: "s", address: "t3"),
        .init(state: "working", name: "Upgrade Postgres to 18", machine: "buildbox",
              lastLine: "Running pg_upgrade checks", host: "b", address: "t11"),
        .init(state: "done", name: "Add a dark mode toggle", machine: "studio",
              lastLine: "Dark mode toggle is ready; tests pass", host: "s", address: "t1"),
    ])
    static let usage = UsageSnapshot(windows: [
        .init(title: "Claude session", percent: 62, detail: "Limit at 3:10 PM"),
        .init(title: "Claude weekly", percent: 41, detail: "Resets Thu 9:00 AM"),
        .init(title: "Codex weekly", percent: 18, detail: ""),
    ], updated: .now)
}
