#!/usr/bin/env bash
set -euo pipefail

status=0

if grep -Ein '"value"[[:space:]]*:[[:space:]]*"[^"]*sidestore' Resources/Localizable.xcstrings; then
  echo "Legacy SideStore branding remains in a localized user-facing value."
  status=1
fi

if grep -REin 'text="[^"]*sidestore|ShareExtensionError\("[^"]*sidestore|ToastView\([^\n]*sidestore' \
  LiveContainerSwiftUI ShareExtension Core/AltStore Core/SideStore/Views \
  --include='*.swift' --include='*.m' --include='*.storyboard'; then
  echo "Legacy SideStore branding remains in a directly rendered user-facing string."
  status=1
fi

if grep -REn '(Text\(|name:|displayName:|appName:|app\.name[[:space:]]*=).*"SideStore"' \
  LiveContainerSwiftUI ShareExtension Core/AltStore Core/SideStore/Views --include='*.swift' --include='*.m'; then
  echo "Legacy SideStore branding remains in a product-facing string."
  status=1
fi

if grep -En '"value"[[:space:]]*:[[:space:]]*"[^"]*LocalDevVPN' Resources/Localizable.xcstrings; then
  echo "User-facing localization must call the connection VPN, not LocalDevVPN."
  status=1
fi

if grep -REn 'LocalDevVPN' Core/AltStore Core/SideStore \
  --include='*.swift' --include='*.m' --include='*.storyboard'; then
  echo "User-facing Core text must call the connection VPN, not LocalDevVPN."
  status=1
fi

exit "$status"
