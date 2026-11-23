#!/bin/zsh -e
# Builds and signs WhitePoint.app next to this script.
cd "${0:A:h}"
app=WhitePoint.app tmp=$(mktemp -d)
trap "rm -rf $tmp" EXIT
rm -rf $app && mkdir -p $app/Contents/{MacOS,Resources} $tmp/icon.iconset
swiftc -O main.swift -o $app/Contents/MacOS/WhitePoint
swift icon.swift $tmp/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s $tmp/icon.png --out $tmp/icon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) $tmp/icon.png --out $tmp/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $tmp/icon.iconset -o $app/Contents/Resources/AppIcon.icns
cp Info.plist $app/Contents/
codesign -f -s 5D2G58P6ZB --options runtime -i com.dullylabs.whitepoint $app
