#!/usr/bin/env bash
set -euo pipefail

status=0

if grep -En '"value"[[:space:]]*:[[:space:]]*"[^"]*SideStore' Resources/Localizable.xcstrings; then
  echo "Legacy SideStore branding remains in a localized user-facing value."
  status=1
fi

if grep -REn '(Text\(|name:|displayName:|appName:|app\.name[[:space:]]*=).*"SideStore"' \
  LiveContainerSwiftUI ShareExtension Core/AltStore Core/SideStore/Views --include='*.swift' --include='*.m'; then
  echo "Legacy SideStore branding remains in a product-facing string."
  status=1
fi

exit "$status"
