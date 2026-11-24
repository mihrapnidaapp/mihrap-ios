"""Copy the Mihrap web app (../mihrap-web/site) into Mihrap/web, add the iOS bridge to app.js and
make the app icon. Photos (slides/) and recordings (audio/) are not bundled: the app downloads
them from the published web version the first time they are needed (WebFiles.swift).

Usage: py -X utf8 sync_web.py
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
SITE = HERE.parent / "mihrap-web" / "site"
WEB = HERE / "Mihrap" / "web"
ASSETS = HERE / "Mihrap" / "Assets.xcassets"
LAUNCHER = HERE.parent / "salahwin" / "android" / "app" / "src" / "main" / "res" / "drawable" / "ic_launcher_art.png"
COPY = ["index.html", "manifest.json", "icon.svg", "css", "js", "data", "fonts", "img", "home", "icons"]

# Inserted inside app.js's closure (it needs rowFor, at, prayerName, settings). Only the iOS app
# defines window.webkit.messageHandlers.mihrap, so the web version is unaffected.
BRIDGE = r'''
  // ------------------------------------------------------------------ iOS app (mihrap-ios)
  // The app shows a silent notification at each prayer time while it is closed (iOS does not let
  // a closed app play the adhan), and downloads the chosen adhan recordings in advance.
  var iosPlanSent = "", iosAudioSent = "";
  function iosBridge() {
    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.mihrap;
    if (!handler) return;
    var items = [], now = new Date();
    if (settings.azan !== "off") {
      for (var d = 0; d < 14 && items.length < 60; ++d) {
        var day = new Date(now.getFullYear(), now.getMonth(), now.getDate() + d);
        var row = rowFor(day);
        if (!row) continue;
        for (var i = 0; i < KEYS.length; ++i) {
          if (KEYS[i] === "Gunes") continue;
          var when = at(row, KEYS[i], day);
          if (!when || when.getTime() <= now.getTime()) continue;
          var place = settings.districtName || settings.cityName || "";
          items.push({ t: when.getTime(), title: prayerName(KEYS[i], day),
            body: pad(when.getHours()) + ":" + pad(when.getMinutes()) + (place ? " · " + place : "") });
        }
      }
    }
    var plan = JSON.stringify(items) + settings.lang;
    if (plan !== iosPlanSent) {
      iosPlanSent = plan;
      try { handler.postMessage({ type: "schedule", items: items }); } catch (e) { }
    }
    var paths = [];
    var collect = function (v) {
      if (typeof v === "string") { if (v.indexOf("audio/") === 0) paths.push(v); }
      else if (v && typeof v === "object") for (var k in v) if (v.hasOwnProperty(k)) collect(v[k]);
    };
    collect(DATA.audio[settings.azan]);
    if (settings.dua) collect(DATA.audio.dua);
    collect(DATA.audio.alert);
    var list = JSON.stringify(paths);
    if (list !== iosAudioSent) {
      iosAudioSent = list;
      try { handler.postMessage({ type: "prefetch", paths: paths }); } catch (e) { }
    }
  }
  setTimeout(iosBridge, 3000);
  setInterval(iosBridge, 20000);

  init();
})();'''


def main() -> None:
    if WEB.exists():
        shutil.rmtree(WEB)
    WEB.mkdir(parents=True)
    for name in COPY:
        src = SITE / name
        if src.is_dir():
            shutil.copytree(src, WEB / name)
        else:
            shutil.copyfile(src, WEB / name)
    app = WEB / "js" / "app.js"
    text = app.read_bytes().decode("utf-8")
    newline = "\r\n" if "\r\n" in text else "\n"
    text = text.replace("\r\n", "\n")
    tail = "\n  init();\n})();"
    assert text.rstrip().endswith(tail.strip()) and text.count("\n  init();\n") == 1, "app.js end changed"
    text = text[: text.rindex("\n  init();")] + BRIDGE + "\n"
    app.write_bytes(text.replace("\n", newline).encode("utf-8"))

    # App icon: the Android launcher art on Mihrap's navy, 1024 px, no transparency (Apple rule).
    icon_dir = ASSETS / "AppIcon.appiconset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    art = Image.open(LAUNCHER).convert("RGBA")
    canvas = Image.new("RGBA", art.size, (7, 26, 48, 255))
    canvas.alpha_composite(art)
    canvas.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(icon_dir / "icon-1024.png", optimize=True)
    (icon_dir / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    (ASSETS / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    color_dir = ASSETS / "LaunchBackground.colorset"
    color_dir.mkdir(exist_ok=True)
    (color_dir / "Contents.json").write_text(json.dumps({
        "colors": [{"idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0.027", "green": "0.102", "blue": "0.188", "alpha": "1.000"}}}],
        "info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
    size = sum(p.stat().st_size for p in WEB.rglob("*") if p.is_file())
    print("web files: %.1f MB" % (size / 1048576))


if __name__ == "__main__":
    main()
