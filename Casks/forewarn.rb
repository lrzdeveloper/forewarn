cask "forewarn" do
  version "1.1.0"
  sha256 "a480fc6d828dd60f76b2b37d74c833a3b1b87525e9327abb41a25051ac34a04d"

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
