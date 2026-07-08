# List TTS Voices MCP Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new `list_voices` MCP tool to let the model query available Kokoro text-to-speech voices with their mechanical properties and local download/cache status.

**Architecture:** Refactor the hardcoded list of 54 voices from the UI view target (`OpenWhisperer`) into a shared, pure Swift model (`TTSVoiceRegistry`) inside `OpenWhispererKit`. Register the `list_voices` tool in `MCPServer`, accepting a callback closure to query local file existence, and consume it inside the loopback HTTP server. Write a developer script to verify drift against the remote Hugging Face Model Hub.

**Tech Stack:** Swift 5.9 (SwiftPM, Command Line Tools), JSON-RPC 2.0 (Model Context Protocol), bash.

## Global Constraints

- macOS 14+ platform requirements.
- Pure library code in `OpenWhispererKit` must not perform file I/O or access application paths directly.
- The default voice list must contain exactly the 54 Kokoro-82M v1.0 voices.
- `swift run OpenWhispererKitTests` and `swift run HookTests` must build and run successfully on CLT.

---

### Task 1: Create TTSVoiceRegistry in OpenWhispererKit

**Files:**
- Create: `app/Sources/OpenWhispererKit/TTSVoiceRegistry.swift`
- Test: `app/Tests/OpenWhispererKitTests/TTSVoiceRegistryChecks.swift`
- Modify: `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift:1-20`

**Interfaces:**
- Produces: `TTSVoice` struct, `TTSVoiceGroup` struct, and `TTSVoiceRegistry` enum with static `groups` and `allVoices`.

- [ ] **Step 1: Write the failing test**

  Create `app/Tests/OpenWhispererKitTests/TTSVoiceRegistryChecks.swift`:
  ```swift
  import Foundation
  import OpenWhispererKit

  func ttsVoiceRegistryFailures() -> [String] {
      var failures: [String] = []
      let all = TTSVoiceRegistry.allVoices
      if all.count != 54 {
          failures.append("TTSVoiceRegistry.allVoices: expected 54 voices, got \(all.count)")
      }
      if !all.contains(where: { $0.id == "af_heart" && $0.gender == "Female" && $0.region == "US" }) {
          failures.append("TTSVoiceRegistry.allVoices: missing af_heart or properties mismatched")
      }
      return failures
  }
  ```

  Modify `app/Tests/OpenWhispererKitTests/SubmitTriggerTests.swift` to register the checks:
  ```diff
  +     failures += ttsVoiceRegistryFailures()
  ```

- [ ] **Step 2: Run test to verify it fails**

  Run: `swift run OpenWhispererKitTests` (from `app/`)
  Expected: FAIL (cannot find 'TTSVoiceRegistry' in scope)

- [ ] **Step 3: Implement TTSVoiceRegistry**

  Create `app/Sources/OpenWhispererKit/TTSVoiceRegistry.swift`:
  ```swift
  import Foundation

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
      
      public init(name: String, voices: [TTSVoice]) {
          self.name = name
          self.voices = voices
      }
  }

  public enum TTSVoiceRegistry {
      public static let groups: [TTSVoiceGroup] = [
          TTSVoiceGroup(name: "English (US)", voices: [
              TTSVoice(id: "af_heart", name: "Heart", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_bella", name: "Bella", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_alloy", name: "Alloy", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_aoede", name: "Aoede", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_jessica", name: "Jessica", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_kore", name: "Kore", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_nicole", name: "Nicole", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_nova", name: "Nova", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_river", name: "River", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_sarah", name: "Sarah", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "af_sky", name: "Sky", language: "English", region: "US", gender: "Female"),
              TTSVoice(id: "am_adam", name: "Adam", language: "English", region: "US", gender: "Male"),
              TTSVoice(id: "am_echo", name: "Echo", language: "English", region: "US", gender: "Male"),
              TTSVoice(id: "am_eric", name: "Eric", language: "English", region: "US", gender: "Male"),
              TTSVoice(id: "am_fenrir", name: "Fenrir", language: "English", region: "US", gender: "Male"),
              TTSVoice(id: "am_liam", name: "Liam", language: "English", region: "US", gender: "Male"),
              TTSVoice(id: "am_michael", name: "Michael", language: "English", region: "US", gender: "Male"),
              TTSVoice(id: "am_onyx", name: "Onyx", language: "English", region: "US", gender: "Male"),
              TTSVoice(id: "am_puck", name: "Puck", language: "English", region: "US", gender: "Male"),
              TTSVoice(id: "am_santa", name: "Santa", language: "English", region: "US", gender: "Male")
          ]),
          TTSVoiceGroup(name: "English (UK)", voices: [
              TTSVoice(id: "bf_alice", name: "Alice", language: "English", region: "UK", gender: "Female"),
              TTSVoice(id: "bf_emma", name: "Emma", language: "English", region: "UK", gender: "Female"),
              TTSVoice(id: "bf_isabella", name: "Isabella", language: "English", region: "UK", gender: "Female"),
              TTSVoice(id: "bf_lily", name: "Lily", language: "English", region: "UK", gender: "Female"),
              TTSVoice(id: "bm_daniel", name: "Daniel", language: "English", region: "UK", gender: "Male"),
              TTSVoice(id: "bm_fable", name: "Fable", language: "English", region: "UK", gender: "Male"),
              TTSVoice(id: "bm_george", name: "George", language: "English", region: "UK", gender: "Male"),
              TTSVoice(id: "bm_lewis", name: "Lewis", language: "English", region: "UK", gender: "Male")
          ]),
          TTSVoiceGroup(name: "French", voices: [
              TTSVoice(id: "ff_siwis", name: "Siwis", language: "French", region: "FR", gender: "Female")
          ]),
          TTSVoiceGroup(name: "Italian", voices: [
              TTSVoice(id: "if_sara", name: "Sara", language: "Italian", region: "IT", gender: "Female"),
              TTSVoice(id: "im_nicola", name: "Nicola", language: "Italian", region: "IT", gender: "Male")
          ]),
          TTSVoiceGroup(name: "Spanish", voices: [
              TTSVoice(id: "ef_dora", name: "Dora", language: "Spanish", region: "ES", gender: "Female"),
              TTSVoice(id: "em_alex", name: "Alex", language: "Spanish", region: "ES", gender: "Male"),
              TTSVoice(id: "em_santa", name: "Santa", language: "Spanish", region: "ES", gender: "Male")
          ]),
          TTSVoiceGroup(name: "Portuguese (BR)", voices: [
              TTSVoice(id: "pf_dora", name: "Dora", language: "Portuguese", region: "BR", gender: "Female"),
              TTSVoice(id: "pm_alex", name: "Alex", language: "Portuguese", region: "BR", gender: "Male"),
              TTSVoice(id: "pm_santa", name: "Santa", language: "Portuguese", region: "BR", gender: "Male")
          ]),
          TTSVoiceGroup(name: "Hindi", voices: [
              TTSVoice(id: "hf_alpha", name: "Alpha", language: "Hindi", region: "IN", gender: "Female"),
              TTSVoice(id: "hf_beta", name: "Beta", language: "Hindi", region: "IN", gender: "Female"),
              TTSVoice(id: "hm_omega", name: "Omega", language: "Hindi", region: "IN", gender: "Male"),
              TTSVoice(id: "hm_psi", name: "Psi", language: "Hindi", region: "IN", gender: "Male")
          ]),
          TTSVoiceGroup(name: "Japanese", voices: [
              TTSVoice(id: "jf_alpha", name: "Alpha", language: "Japanese", region: "JP", gender: "Female"),
              TTSVoice(id: "jf_gongitsune", name: "Gongitsune", language: "Japanese", region: "JP", gender: "Female"),
              TTSVoice(id: "jf_nezumi", name: "Nezumi", language: "Japanese", region: "JP", gender: "Female"),
              TTSVoice(id: "jf_tebukuro", name: "Tebukuro", language: "Japanese", region: "JP", gender: "Female"),
              TTSVoice(id: "jm_kumo", name: "Kumo", language: "Japanese", region: "JP", gender: "Male")
          ]),
          TTSVoiceGroup(name: "Chinese", voices: [
              TTSVoice(id: "zf_xiaobei", name: "Xiaobei", language: "Chinese", region: "CN", gender: "Female"),
              TTSVoice(id: "zf_xiaoni", name: "Xiaoni", language: "Chinese", region: "CN", gender: "Female"),
              TTSVoice(id: "zf_xiaoxiao", name: "Xiaoxiao", language: "Chinese", region: "CN", gender: "Female"),
              TTSVoice(id: "zf_xiaoyi", name: "Xiaoyi", language: "Chinese", region: "CN", gender: "Female"),
              TTSVoice(id: "zm_yunjian", name: "Yunjian", language: "Chinese", region: "CN", gender: "Male"),
              TTSVoice(id: "zm_yunxi", name: "Yunxi", language: "Chinese", region: "CN", gender: "Male"),
              TTSVoice(id: "zm_yunxia", name: "Yunxia", language: "Chinese", region: "CN", gender: "Male"),
              TTSVoice(id: "zm_yunyang", name: "Yunyang", language: "Chinese", region: "CN", gender: "Male")
          ])
      ]

      public static var allVoices: [TTSVoice] {
          groups.flatMap { $0.voices }
      }
  }
  ```

- [ ] **Step 4: Run test to verify it passes**

  Run: `swift run OpenWhispererKitTests`
  Expected: PASS

- [ ] **Step 5: Commit**

  Run:
  ```bash
  git add Sources/OpenWhispererKit/TTSVoiceRegistry.swift Tests/OpenWhispererKitTests/TTSVoiceRegistryChecks.swift Tests/OpenWhispererKitTests/SubmitTriggerTests.swift
  git commit -m "refactor(voice): extract static voice registry to OpenWhispererKit"
  ```

---

### Task 2: Refactor SwiftUI MenuBarView to consume TTSVoiceRegistry

**Files:**
- Modify: `app/Sources/OpenWhisperer/MenuBarView.swift:110-150`

**Interfaces:**
- Consumes: `TTSVoiceRegistry.groups`, `TTSVoiceRegistry.allVoices`

- [ ] **Step 1: Replace hardcoded arrays in MenuBarView**

  Open `app/Sources/OpenWhisperer/MenuBarView.swift` and locate lines 110–149.
  Replace:
  ```swift
      private static let voiceGroups: [(group: String, options: [(id: String, label: String)])] = [
          // ... hardcoded options ...
      ]

      /// Flattened roster for collapsed-label lookup and load-time validation.
      private static var allVoices: [(id: String, label: String)] {
          voiceGroups.flatMap { $0.options }
      }
  ```
  with:
  ```swift
      private static var voiceGroups: [(group: String, options: [(id: String, label: String)])] {
          TTSVoiceRegistry.groups.map { group in
              (group.name, group.voices.map { ($0.id, "\($0.name) (\($0.gender.prefix(1)))") })
          }
      }

      private static var allVoices: [(id: String, label: String)] {
          TTSVoiceRegistry.allVoices.map { ($0.id, "\($0.name) (\($0.gender.prefix(1)))") }
      }
  ```

- [ ] **Step 2: Build the app to verify it compiles**

  Run: `swift build` (from `app/`)
  Expected: Build complete! (0 warnings/errors in MenuBarView)

- [ ] **Step 3: Commit**

  Run:
  ```bash
  git add Sources/OpenWhisperer/MenuBarView.swift
  git commit -m "refactor(ui): update MenuBarView to populate voices from shared registry"
  ```

---

### Task 3: Support list_voices in MCPServer

**Files:**
- Modify: `app/Sources/OpenWhispererKit/MCPServer.swift:23-88`
- Modify: `app/Tests/OpenWhispererKitTests/MCPServerChecks.swift:1-138`

**Interfaces:**
- Consumes: `TTSVoiceRegistry.allVoices`
- Produces: `MCPServer.handle(body:isVoiceCached:)` which handles the `list_voices` JSON-RPC method.

- [ ] **Step 1: Write the failing test**

  Open `app/Tests/OpenWhispererKitTests/MCPServerChecks.swift`.
  Add a test block to `mcpServerFailures()` for `list_voices`:
  ```swift
      // tools/list → advertises `list_voices`
      if case let .json(data) = req(#"{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{}}"#),
         let result = decode(data)?["result"] as? [String: Any],
         let tools = result["tools"] as? [[String: Any]],
         let listVoices = tools.first(where: { ($0["name"] as? String) == "list_voices" }) {
          let schema = listVoices["inputSchema"] as? [String: Any]
          if schema?["properties"] == nil { failures.append("tools/list: list_voices inputSchema properties missing") }
      } else {
          failures.append("tools/list: expected list_voices tool in .json outcome")
      }

      // tools/call list_voices → returns the serialized voices list with correct cached state
      let mockIsCached: (String) -> Bool = { $0 == "af_heart" }
      switch server.handle(Data(#"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"list_voices"}}"#.utf8), isVoiceCached: mockIsCached) {
      case let .json(data):
          if let r = decode(data)?["result"] as? [String: Any],
             let content = r["content"] as? [[String: Any]],
             let text = content.first?["text"] as? String,
             let bodyData = text.data(using: .utf8),
             let voicesObj = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
             let voicesList = voicesObj["voices"] as? [[String: Any]] {
              if voicesList.count != 54 { failures.append("list_voices tool: expected 54 voices, got \(voicesList.count)") }
              if let heart = voicesList.first(where: { ($0["id"] as? String) == "af_heart" }) {
                  if (heart["cached"] as? Bool) != true { failures.append("list_voices tool: af_heart cached should be true") }
              } else { failures.append("list_voices tool: missing af_heart") }
              if let bella = voicesList.first(where: { ($0["id"] as? String) == "af_bella" }) {
                  if (bella["cached"] as? Bool) != false { failures.append("list_voices tool: af_bella cached should be false") }
              } else { failures.append("list_voices tool: missing af_bella") }
          } else { failures.append("list_voices tool: invalid response shape") }
      default:
          failures.append("list_voices tool: expected .json outcome")
      }
  ```

- [ ] **Step 2: Run test to verify it fails**

  Run: `swift run OpenWhispererKitTests`
  Expected: FAIL (tools/list fails to find `list_voices` in output; `list_voices` call fails)

- [ ] **Step 3: Implement list_voices in MCPServer**

  Open `app/Sources/OpenWhispererKit/MCPServer.swift`.
  Change `public func handle(_ body: Data) -> MCPOutcome` to:
  ```swift
  public func handle(_ body: Data, isVoiceCached: (String) -> Bool = { _ in false }) -> MCPOutcome
  ```
  Add the `list_voices` schema to `tools/list`:
  ```swift
          case "tools/list":
              let speak: [String: Any] = [
                  "name": "speak",
                  "description": "Synthesize and play the given text aloud through OpenWhisperer's "
                      + "local voice (text-to-speech). Fire-and-forget: returns immediately while audio plays.",
                  "inputSchema": [
                      "type": "object",
                      "properties": [
                          "text": ["type": "string", "description": "The text to speak aloud."],
                          "voice": ["type": "string", "description": "Optional Kokoro voice id; defaults to the user's selected voice."],
                          "speed": ["type": "number", "description": "Optional playback speed, 0.7–1.5; defaults to the user's setting."],
                      ],
                      "required": ["text"],
                  ],
              ]
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
  Add `list_voices` tool execution to `tools/call`:
  ```swift
          case "tools/call":
              let name = params["name"] as? String ?? ""
              let args = params["arguments"] as? [String: Any] ?? [:]
              if name == "list_voices" {
                  let voiceList = TTSVoiceRegistry.allVoices.map { voice -> [String: Any] in
                      return [
                          "id": voice.id,
                          "name": voice.name,
                          "language": voice.language,
                          "region": voice.region,
                          "gender": voice.gender,
                          "cached": isVoiceCached(voice.id)
                      ]
                  }
                  let voiceData = (try? JSONSerialization.data(withJSONObject: ["voices": voiceList], options: [.prettyPrinted])) ?? Data()
                  let response = Self.resultResponse(id: requestID, result: [
                      "content": [["type": "text", "text": String(data: voiceData, encoding: .utf8) ?? ""]],
                      "isError": false,
                  ])
                  return .json(response)
              }
              guard name == "speak" else {
                  return .json(Self.toolError(id: requestID, message: "Unknown tool: \(name)"))
              }
  ```

- [ ] **Step 4: Run test to verify it passes**

  Run: `swift run OpenWhispererKitTests`
  Expected: PASS

- [ ] **Step 5: Commit**

  Run:
  ```bash
  git add Sources/OpenWhispererKit/MCPServer.swift Tests/OpenWhispererKitTests/MCPServerChecks.swift
  git commit -m "feat(mcp): support list_voices tool in MCPServer"
  ```

---

### Task 4: Connect file existence closure in HTTP Server

**Files:**
- Modify: `app/Sources/OpenWhisperer/TTSHTTPServer.swift:140-150`

**Interfaces:**
- Consumes: `MCPServer.handle(body:isVoiceCached:)`

- [ ] **Step 1: Inject isVoiceCached closure into handle call**

  Open `app/Sources/OpenWhisperer/TTSHTTPServer.swift` and find line 140:
  ```swift
              switch MCPServer().handle(req.body) {
  ```
  Replace it with:
  ```swift
              let isVoiceCached: (String) -> Bool = { voice in
                  let sanitized = voice.filter { $0.isLetter || $0.isNumber || $0 == "_" }
                  guard !sanitized.isEmpty else { return false }
                  if sanitized == "af_heart" { return true }
                  let home = FileManager.default.homeDirectoryForCurrentUser
                  let path = home.appendingPathComponent(".cache/fluidaudio/Models/kokoro-82m-coreml/ANE/\(sanitized).bin").path
                  return FileManager.default.fileExists(atPath: path)
              }
              switch MCPServer().handle(req.body, isVoiceCached: isVoiceCached) {
  ```

- [ ] **Step 2: Verify full build compiles and HookTests pass**

  Run: `swift build && swift run HookTests` (from `app/`)
  Expected: Build complete! HookTests: all checks passed

- [ ] **Step 3: Commit**

  Run:
  ```bash
  git add Sources/OpenWhisperer/TTSHTTPServer.swift
  git commit -m "feat(mcp): wire local cache existence check into MCP server handler"
  ```

---

### Task 5: Create catalog drift verification script

**Files:**
- Create: `scripts/check-voices-drift.sh`

**Interfaces:**
- Consumes: Hugging Face model hub tree API

- [ ] **Step 1: Create the drift verification script**

  Create `scripts/check-voices-drift.sh`:
  ```bash
  #!/bin/bash
  # Check if our static voice catalog has drifted from the remote HuggingFace repository
  set -e

  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
  REGISTRY_FILE="$PROJECT_DIR/app/Sources/OpenWhispererKit/TTSVoiceRegistry.swift"

  echo "=== Fetching voices from HuggingFace ONNX repository ==="
  HF_JSON=$(curl -s "https://huggingface.co/api/models/onnx-community/Kokoro-82M-v1.0-ONNX/tree/main/voices")

  # Extract remote voices
  REMOTE_VOICES=$(echo "$HF_JSON" | jq -r '.[] | select(.type == "file") | .path | split("/")[-1] | split(".bin")[0]' | sort)

  # Extract local voices from Swift file
  LOCAL_VOICES=$(grep -o 'id: "[^"]*"' "$REGISTRY_FILE" | cut -d'"' -f2 | sort)

  echo "=== Comparing catalogs ==="
  DRIFT=0

  # Check for remote voices missing locally
  for voice in $REMOTE_VOICES; do
      if ! echo "$LOCAL_VOICES" | grep -q "^$voice$"; then
          echo "⚠️  Missing locally: $voice (available on HuggingFace)"
          DRIFT=1
      fi
  done

  # Check for local voices missing remotely
  for voice in $LOCAL_VOICES; do
      if ! echo "$REMOTE_VOICES" | grep -q "^$voice$"; then
          echo "⚠️  Orphaned locally: $voice (not found on HuggingFace)"
          DRIFT=1
      fi
  done

  if [ $DRIFT -eq 0 ]; then
      echo "✅ Voice catalogs are in perfect sync!"
      exit 0
  else
      echo "❌ Catalog drift detected."
      exit 1
  fi
  ```

  Make the script executable:
  ```bash
  chmod +x scripts/check-voices-drift.sh
  ```

- [ ] **Step 2: Run verification script**

  Run: `scripts/check-voices-drift.sh` (from project root)
  Expected: Perfect sync (exit 0)

- [ ] **Step 3: Commit**

  Run:
  ```bash
  git add scripts/check-voices-drift.sh
  git commit -m "test(voice): add developer utility script to check voice catalog drift"
  ```
