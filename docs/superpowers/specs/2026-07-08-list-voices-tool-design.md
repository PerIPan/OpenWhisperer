# List TTS Voices MCP Tool

**Date:** 2026-07-08
**Status:** Approved (brainstorming) — pending implementation plan

## Goal

Expose a new `list_voices` tool via the Model Context Protocol (MCP) server so that the model can dynamically discover the full roster of available text-to-speech (TTS) voices, their regional/gender characteristics, and whether they are already cached locally.

1. **Roster Discovery.** Let the model query the supported voices instead of guessing voice IDs.
2. **Offline-First Check.** Report whether each voice's binary weights (`.bin`) are already downloaded to the local cache (`~/.cache/fluidaudio`), helping the model avoid triggering network downloads that might fail under firewalls or offline conditions.
3. **Registry Centralization.** Extract the hardcoded roster of 54 voices from the SwiftUI code in `MenuBarView.swift` and consolidate it into a unified, pure Swift model inside `OpenWhispererKit`.
4. **Drift Detection.** Provide a developer utility script to compare our local static registry against the remote Hugging Face repository assets, ensuring we stay synchronized with any new voice releases.

### Why this, why now

The `speak` tool accepts an optional `voice` parameter, but models currently have no way of knowing what voices are actually supported, what they sound like, or whether they are already available offline. Centralizing this list makes the `voice` parameter truly dynamic and actionable for the model, while improving codebase architecture by removing data models from UI view code.

## Decisions

- **Strictly Mechanical Metadata.** Voice descriptions will remain strictly factual (Language, Region, Gender). Creative persona attributes (e.g., "dry and unflappable") will remain in the prompt-level logic rather than hardcoded in the voice catalog.
- **Exposed as an MCP Tool.** We will register a new tool `list_voices` in the existing `tools/list` and `tools/call` JSON-RPC handlers, rather than implementing new MCP Resources protocol handlers (`resources/list`, `resources/read`), keeping our lightweight loopback server clean and simple.
- **Dynamic Caching Status.** The tool response will include a `cached` boolean for each voice, checked dynamically at invocation time by validating the presence of the corresponding `.bin` file on disk.
- **Pure / Non-I/O Library Seam.** To keep `OpenWhispererKit` completely pure and unit-testable under Command Line Tools (without hardcoding file paths or disk accesses inside the library target), `MCPServer` will accept a closure parameter `isVoiceCached: (String) -> Bool` when handling requests. The application target will inject the real file-system check.

## Non-goals (YAGNI)

- No dynamic runtime downloading of voices during the `list_voices` call itself (downloading remains lazy and is triggered on first play inside `ensureVoicePack`).
- No search or filtering arguments in the `list_voices` tool; it will always return the full list.
- No dynamic web crawling in the app runtime to fetch voices; it relies on the static `TTSVoiceRegistry`.

## Approach

### 1. Unified Voice Model (`OpenWhispererKit`)

We will define `TTSVoice` and `TTSVoiceRegistry` in a new file `app/Sources/OpenWhispererKit/TTSVoiceRegistry.swift`:

```swift
public struct TTSVoice: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let language: String
    public let region: String
    public let gender: String
    public var cached: Bool?

    public init(id: String, name: String, language: String, region: String, gender: String, cached: Bool? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.region = region
        self.gender = gender
        self.cached = cached
    }
}

public struct TTSVoiceGroup: Sendable {
    public let name: String
    public let voices: [TTSVoice]
}

public enum TTSVoiceRegistry {
    public static let groups: [TTSVoiceGroup] = [
        TTSVoiceGroup(name: "English (US)", voices: [
            TTSVoice(id: "af_heart", name: "Heart", language: "English", region: "US", gender: "Female"),
            // ... all 54 voices mapped here
        ]),
        // ... other language groups
    ]

    public static var allVoices: [TTSVoice] {
        groups.flatMap { $0.voices }
    }
}
```

### 2. UI Menu Integration (`OpenWhisperer`)

We will update [MenuBarView.swift](file:///Users/hakanensari/code/OpenWhisperer/app/Sources/OpenWhisperer/MenuBarView.swift) to discard the private static `voiceGroups` array and build its submenus dynamically from `TTSVoiceRegistry.groups`.

### 3. MCP Tool Dispatch (`OpenWhispererKit` + `OpenWhisperer`)

We will register `list_voices` in [MCPServer.swift](file:///Users/hakanensari/code/OpenWhisperer/app/Sources/OpenWhispererKit/MCPServer.swift):

```swift
// In MCPServer.swift
case "tools/list":
    let speak = [...]
    let listVoices: [String: Any] = [
        "name": "list_voices",
        "description": "Retrieve the list of available text-to-speech voices, including their language, region, gender, and local cache status.",
        "inputSchema": [
            "type": "object",
            "properties": [String: Any]()
        ]
    ]
    return .json(Self.resultResponse(id: requestID, result: ["tools": [speak, listVoices]]))
```

We will extend `MCPServer.handle` to accept the filesystem cache closure:

```swift
public func handle(_ body: Data, isVoiceCached: (String) -> Bool) -> MCPOutcome {
    // ...
    case "tools/call":
        let name = params["name"] as? String ?? ""
        if name == "list_voices" {
            let voices = TTSVoiceRegistry.allVoices.map { voice in
                TTSVoice(
                    id: voice.id,
                    name: voice.name,
                    language: voice.language,
                    region: voice.region,
                    gender: voice.gender,
                    cached: isVoiceCached(voice.id)
                )
            }
            let payload: [String: Any] = ["voices": voices.map { /* serialize to dictionary */ }]
            let response = Self.resultResponse(id: requestID, result: [
                "content": [["type": "text", "text": Self.jsonString(payload)]],
                "isError": false
            ])
            return .json(response)
        }
    // ...
}
```

In `TTSHTTPServer.swift`, the HTTP request handler will execute the real file existence check on disk via `FileManager.default.fileExists(atPath:)` at `~/.cache/fluidaudio/Models/kokoro-82m-coreml/ANE/<voice>.bin` and pass the closure into the server handle.

### 4. Drift Checking Script (`scripts/check-voices-drift.sh`)

We will write a developer script `scripts/check-voices-drift.sh`:
1. Fetches the current voice catalog from the Hugging Face Model Hub tree API.
2. Extracts the filenames ending in `.bin`.
3. Parses our `TTSVoiceRegistry.swift` file for defined IDs.
4. Outputs any differences (voices present on Hugging Face but missing from our Swift code).

## Testing Plan

1. **Unit Tests (`OpenWhispererKitTests`):**
   - Verify `TTSVoiceRegistry.allVoices` contains all 54 expected entries.
   - Verify `MCPServer.handle` responds to `tools/list` with both `speak` and `list_voices` tools.
   - Verify calling `list_voices` returns the JSON payload containing the voices, and that the `cached` attribute mirrors the closure input correctly (tested with stubs).
2. **Integration Tests (`HookTests`):**
   - Verify that model commands/MCP calls interact correctly.
3. **Manual Check:**
   - Execute `scripts/check-voices-drift.sh` and ensure it runs successfully and returns no drift against the live Hugging Face repository.
