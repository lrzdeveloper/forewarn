cask "forewarn" do
  version "1.0.0"
  sha256 "14f1a25cb541845cec740ab1195a475815e64f51ae8c50d4f29b2a941263dc14"

  url "https://github.com/lrzdeveloper/forewarn/releases/download/v#{version}/Forewarn-#{version}.dmg"
  name "Forewarn"
  desc "Menu bar app that warns before the battery, disk or mobile data run out"
  homepage "https://github.com/lrzdeveloper/forewarn"

  depends_on macos: :tahoe

  app "Forewarn.app"

  uninstall quit: "io.github.lrzdeveloper.forewarn"

  zap trash: [
    "~/Library/Application Support/Forewarn",
    "~/Library/Caches/io.github.lrzdeveloper.forewarn",
    "~/Library/Preferences/io.github.lrzdeveloper.forewarn.plist",
  ]
end
