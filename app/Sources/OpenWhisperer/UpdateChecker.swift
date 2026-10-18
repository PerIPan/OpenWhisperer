import AppKit
import Combine
import OpenWhispererKit
import os.log

private let updateLog = OSLog(subsystem: "com.openwhisperer", category: "update")

/// Once a day, asks GitHub for the latest release and, when it's newer than this build, offers
/// it in the menubar and Settings → General. Never downloads or installs — see `UpdateCheck`.
///
/// The only network call the app makes besides model downloads, and it carries nothing of the
/// user's: a plain HTTPS GET of a public endpoint. On by default, because the point is to reach
/// people who installed a DMG and would otherwise never hear of a fix; Settings → General turns
/// it off (`update_check_off`).
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// A newer release, when there is one.
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var isEnabled = !FileManager.default.fileExists(atPath: Paths.updateCheckOff.path)
    /// Shown under the toggle after a manual check, so "Check now" visibly did something.
    @Published private(set) var lastResult: String?

    private var timer: Timer?
    private var inFlight = false
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""

    private init() {
        // A relaunch inside the day keeps showing what the last check found.
        let memo = UpdateCheck.parseMemo(try? String(contentsOf: Paths.updateCheckMemo, encoding: .utf8))
        available = isEnabled ? UpdateCheck.available(current: currentVersion, latest: memo.latest) : nil
    }

    /// Called once at launch. The first check waits 30 s so it never competes with the
    /// model load for the launch; after that an hourly tick asks only when a day has passed.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
        let timer = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer.tolerance = 5 * 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setEnabled(_ on: Bool) {
        if on {
            try? FileManager.default.removeItem(at: Paths.updateCheckOff)
        } else {
            try? "".write(to: Paths.updateCheckOff, atomically: true, encoding: .utf8)
        }
        isEnabled = !FileManager.default.fileExists(atPath: Paths.updateCheckOff.path)
        if isEnabled { checkNow() } else { available = nil; lastResult = nil }
    }

    func checkIfDue() {
        guard isEnabled else { return }
        let memo = UpdateCheck.parseMemo(try? String(contentsOf: Paths.updateCheckMemo, encoding: .utf8))
        guard UpdateCheck.isDue(lastChecked: memo.checkedAt, now: Date()) else { return }
        fetch(manual: false)
    }

    /// Settings → General "Check now".
    func checkNow() {
        guard isEnabled else { return }
        fetch(manual: true)
    }

    func openReleasePage() {
        guard let url = available?.pageURL else { return }
        NSWorkspace.shared.open(url)
    }

    private func fetch(manual: Bool) {
        guard !inFlight else { return }
        inFlight = true
        var request = URLRequest(url: UpdateCheck.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenWhisperer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let latest = (status == 200 ? data : nil).flatMap(UpdateCheck.parseLatest)
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard status == 200, latest != nil else {
                    // A failed check changes nothing and isn't memoised, so the next tick retries.
                    os_log(.default, log: updateLog, "Update check failed (HTTP %d): %{public}@",
                           status, error?.localizedDescription ?? "unparseable response")
                    if manual { self.lastResult = "Couldn't reach GitHub — try again later." }
                    return
                }
                try? UpdateCheck.memo(checkedAt: Date(), latest: latest)
                    .write(to: Paths.updateCheckMemo, atomically: true, encoding: .utf8)
                guard self.isEnabled else { return }   // turned off while the request was out
                self.available = UpdateCheck.available(current: self.currentVersion, latest: latest)
                if manual {
                    self.lastResult = self.available.map { "Version \($0.version) is available." }
                        ?? "You're on the latest version."
                }
                os_log(.default, log: updateLog, "Update check: latest %{public}@, running %{public}@",
                       latest.map { "\($0.version)" } ?? "?", self.currentVersion)
            }
        }.resume()
    }
}
