# EchoGuide with an AI assistant

EchoGuide uses local tools. No account, cloud service, or AI subscription is required by EchoGuide itself. An assistant can inspect readiness, read local progress, request native approvals, and obtain a redacted diagnostic report. It cannot approve its own device-writing request.

## Build and configure

Build on a Mac with Swift 6 using `swift build`. On external or network volumes, use a local scratch directory, for example `swift build --scratch-path /private/tmp/EchoGuideBuild`.

Keep the SwiftPM-generated `EchoGuide_EchoGuideCore.bundle` beside the CLI/MCP executables when installing them outside the app. Install `echo-guide-mcp` in a stable local location and configure your client's stdio MCP launcher with its absolute path. Paths below are placeholders, not executable defaults.

For Claude Desktop, merge this server entry into its existing MCP configuration:

```json
{"mcpServers":{"echo-guide":{"command":"/absolute/path/echo-guide-mcp","args":[]}}}
```

For Codex, add this entry to its existing configuration:

```toml
[mcp_servers.echoguide]
command = "/absolute/path/echo-guide-mcp"
args = []
```

Both client configurations are examples and are **not yet client-integration tested**. Do not replace unrelated configuration. Other clients need the same executable, no arguments, and newline-framed stdio JSON-RPC. The packaged `skills/echo-guide` folder can be copied to a client's skill directory when supported; the Markdown is portable guidance for other assistants.

## Tools and limits

| Tool | Behavior |
|---|---|
| `inspect` | Inspect Mac readiness |
| `prepare_downloads` | Start pinned publisher downloads in the private app-owned directory; return operation ID |
| `status` | Read the private local session |
| `powered_wait_status` | Read saved waiting-period safety guidance without private IDs or paths |
| `verify_recovery` | Verify compatible recovery using app-selected ADB and device |
| `backup` | Start verified backup capture and return its persistent operation ID |
| `request_unlock` | Create a pending native approval request |
| `request_install` | Create a pending native approval request |
| `report` | Produce redacted shareable diagnostics |

Select the ADB executable, device, and private backup destination in the native app first. Recovery and backup calls fail with setup guidance until configured. All tools take an empty argument object. The server uses `~/Library/Application Support/EchoGuide`; callers cannot provide paths, commands, payloads, credentials, or approval decisions. Keep the native app running to receive approval notifications. If it is closed, launch it and review the saved pending request; the server does not install or launch another app. The native app and backend enforce prerequisites. A request may be rejected before approval if readiness is incomplete.

After `backup` returns, poll `status` for that operation ID and `backupProgress`. A returned ID means the operation was reserved, not completed. Success requires its terminal successful outcome and verified backup manifest. Graceful server input closure waits for an active transfer; forced termination leaves an incomplete intent requiring inspection and never automatically restarts the capture. The CLI backup command remains synchronous.

Preview releases do not imply that a pending request executes an unlock or installation. Consult the release's prototype-status document for implemented and experimentally validated operations. The server supports MCP initialization, tool listing/calling, and ping; it does not implement arbitrary filesystem resources or prompts.

The CLI supports `inspect`, `status`, `verify-recovery`, `backup`, `request-unlock`, `request-install`, and `report`. Its optional `--state-root DIRECTORY` is a manual development configuration, not an MCP input. Never share raw `status` output: use `report` and review it first.


`prepare_downloads` takes no arguments and uses the bundled profile's publishers, sizes, and SHA-256 values. It saves under the private session's `downloads` directory. Poll `status.downloadProgress` and the matching operation record; transferred bytes are not verified-file proof. A failed or cancelled operation is not a prepared VM. Existing verified files can be reused during an explicit retry; mismatching files are preserved and rejected. Graceful stdio EOF waits for both backups and publisher downloads, while forced termination leaves an incomplete intent requiring inspection.

The CLI command `echo-guide prepare-downloads` waits for the same preparation result. No caller can supply publisher URLs, artifacts, or a destination through MCP. App folder selection remains a separate user-controlled download workflow using the same core verifier.


Use `powered_wait_status` (CLI: `powered-wait-status`) to inspect saved waiting-period evidence. It takes no arguments, performs no device or payload operations, and returns null when there is no saved record. An incomplete record means keep wall power connected and inspect before proceeding; it never authorizes another attempt or restarts a timer. A completed recorded wait does not prove the Echo stayed powered or that unlocking succeeded. Independently verify compatible recovery. Invalid evidence fails closed with keep-power guidance. The native app displays this safety state outside technical session details after refresh.
