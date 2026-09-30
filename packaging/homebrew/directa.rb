# Canonical Homebrew cask for directa. This is the single home for the cask's
# structure; the release workflow (.github/workflows/bump-homebrew-cask.yml)
# reads this file, substitutes `version` and `sha256` for the published release,
# and writes the result to the quantizor/homebrew-tap repo. scripts/smoke-cask.sh
# copies it into a throwaway local tap, rewriting the URL to a local file:// DMG
# with the real checksum, so the whole thing is testable before any release.
#
# The version and sha256 below are whatever the last release set; treat them as
# illustrative, since both are always overwritten on publish.
cask "directa" do
  version "1.3.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/quantizor/directa/releases/download/v#{version}/directa-#{version}.dmg"
  name "directa"
  desc "Agent-friendly coordinator for many devservers and their configurations"
  homepage "https://github.com/quantizor/directa"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "directa.app"
  binary "#{appdir}/directa.app/Contents/Resources/directa"

  # This runs on every `brew upgrade`, not only on uninstall, so it is limited to
  # unregistering the background agent, which the app re-registers when brew
  # relaunches it. It must never touch agent hooks or user data: nothing restores
  # those automatically, by design. Full removal is `directa uninstall`.
  #
  # early_script rather than script, because a plain `script` runs after `quit:`,
  # and the CLI needs a live app to drive SMAppService.unregister over the deep
  # link. There is no launchctl: stanza (it would boot out the SMAppService job on
  # every upgrade) and no login_item: stanza (it cannot see a BTM registration);
  # the agent teardown is delegated to directa's own CLI, the only lever that
  # reaches BTM.
  #
  # Footgun worth naming: trashing the app and THEN running `brew uninstall`
  # leaves this executable missing, so uninstall raises rather than skipping.
  # Recovery is `brew uninstall --cask --force directa`. This is inherent to any
  # cask whose uninstall script ships inside the bundle it removes.
  uninstall early_script: {
              executable: "#{appdir}/directa.app/Contents/Resources/directa",
              args:       ["uninstall", "--agent-only", "--json"],
            },
            quit:         "dev.quantizor.directa.app"

  # trash:, not delete:, so removal is recoverable and needs no sudo. The bundle
  # is already gone by the time zap runs (uninstall_artifacts runs first), so
  # nothing here can shell out to the CLI; these are the files directa leaves in
  # the user's Library.
  zap trash: [
    "~/Library/Application Support/directa",
    "~/Library/Caches/dev.quantizor.directa.app",
    "~/Library/Caches/dev.quantizor.ddirecta",
    "~/Library/Caches/ddirecta",
    "~/Library/HTTPStorages/dev.quantizor.ddirecta",
    "~/Library/HTTPStorages/ddirecta",
    "~/Library/LaunchAgents/dev.quantizor.directa.plist",
    "~/Library/Logs/directa",
    "~/Library/Preferences/dev.quantizor.directa.app.plist",
    "~/Library/Saved Application State/dev.quantizor.directa.app.savedState",
  ]

  caveats <<~EOS
    directa is a menu bar app with a small background agent that supervises your
    dev servers. Homebrew installed it but does not start it; open the app once
    to start the agent:

        open -a directa

    macOS asks you to confirm the first launch (it is notarized, so this is a
    one-time click). After that the agent starts at login and the menu bar icon
    shows your servers. Then wire up your coding agents:

        directa hook install

    To remove directa's agent hooks and CLI state as well, run `directa uninstall`
    before uninstalling this cask.
  EOS
end
