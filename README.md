# FlagDash Swift SDK

Feature flags, remote config and AI configs for iOS 15+ and macOS 12+.

Built on Swift concurrency: `FlagDashClient` is an `actor`, so it is safe to
share across tasks without a lock of your own.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/flagdash/flagdash-swift.git", from: "0.1.0")
]
```

Then add `FlagDash` to your target's dependencies.

## Quick start

```swift
import FlagDash

let client = FlagDashClient(sdkKey: ProcessInfo.processInfo.environment["FLAGDASH_SDK_KEY"]!)

let context = EvaluationContext(userID: "alice")

if case .bool(true) = await client.flag("checkout-v2", default: .bool(false), context: context) {
    // new checkout
}
```

## What this SDK covers

| Capability | Supported |
|---|---|
| Feature flags, with context and evaluation detail | Yes |
| Remote config | Yes |
| AI configs | Yes |
| Translations | **Not yet** — use the Management API |
| Experiments and metrics | **Not yet** — use a server SDK |

The client tier is what an app should ship, and translations and experiments
are server-key features, so they are deliberately absent here rather than
present and unusable.

## API keys

Ship a **client key** (`pk_`). It carries the project and environment, which is
why no method takes an `environment` argument, and it never returns targeting
rules — an app cannot see who else you are targeting.

Never embed a server key (`sk_`) in an app bundle. Anything shipped to a device
is readable.

## Configuration

```swift
let client = FlagDashClient(
    sdkKey: key,
    baseURL: URL(string: "https://flagdash.io")!,  // self-hosted? point it here
    timeout: 5,                                    // seconds
    cacheTTL: 60,                                  // seconds
    region: "eu-west-1",                           // omit to auto-detect
    transport: URLSessionTransport()               // inject for tests
)
```

An empty `sdkKey` trips a `precondition` — a missing key should fail loudly at
start-up rather than quietly serve defaults forever.

## Evaluation context

```swift
let context = EvaluationContext(
    userID: "alice",
    attributes: ["country": "GB", "plan": "premium"]
)
```

**Set `userID`** (or `unitID`) whenever you want a stable answer. Percentage
rollouts and A/B variations hash it, so a context without one re-rolls on every
call by design.

## Feature flags

Values are `JSONValue` — `.bool`, `.string`, `.number`, `.object`, `.array`,
`.null` — so a flag of any type round-trips without a separate API per type.

```swift
// One flag, with the fallback used whenever FlagDash cannot be reached.
let value = await client.flag("checkout-v2", default: .bool(false), context: context)

// Every flag for this context, in one request.
let flags = await client.allFlags(context: context)

// Why did it resolve that way?
let detail = await client.flagDetail("checkout-v2", default: .bool(false), context: context)
detail.value
detail.reason        // "rule_match", "rollout", "default", ...
```

Reading a value:

```swift
switch await client.flag("banner-copy", default: .string("control"), context: context) {
case .string(let copy): show(copy)
default: show("control")
}
```

## Remote config

```swift
let limit = await client.config("rate_limit", default: .number(100))
let all = await client.listConfigs()
```

## AI configs

Prompts, agents, skills and rules, versioned per environment and editable
without an App Store release.

```swift
if let agent = await client.aiConfig("support-agent.md") {
    // agent["content"]
}

let files = await client.listAIConfigs()
```

## Caching

Reads are cached in memory for `cacheTTL` (60s by default), so a burst of
`flag` calls costs one request.

```swift
await client.clearCache()
```

A mobile client is usually best served by evaluating on launch and on
foreground rather than per view.

## Failure behaviour

Every read returns the default you passed. There are no throwing calls on the
read path, so a flaky network degrades to your fallback values instead of
propagating an error into UI code.

## License

MIT
