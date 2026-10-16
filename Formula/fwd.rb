class Fwd < Formula
  desc "SSH port forwarding for the macOS menu bar"
  homepage "https://github.com/kylefritz/fwd"
  url "https://github.com/kylefritz/fwd/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  def install
    # Built here rather than downloaded, so the app is never quarantined.
    system "swift", "build", "--disable-sandbox", "-c", "release"
    ENV["VERSION"] = version.to_s
    system "scripts/bundle.sh"
    prefix.install "build/fwd.app"
    bin.install_symlink prefix/"fwd.app/Contents/Resources/bin/fwd"
  end

  def caveats
    <<~EOS
      Start fwd from a terminal with:
        fwd open
      It lives in the menu bar. `fwd` alone lists the commands. Ports are kept in ~/.config/fwd/ports.yaml.
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/fwd --version").strip
  end
end
