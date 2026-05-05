#!/bin/bash
# Install ralph globally on this workstation.
set -euo pipefail

INSTALL_DIR="${RALPH_HOME:-$HOME/.ralph}"
LINK_DIR="${HOME}/.local/bin"

echo "Installing ralph to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
cp -r bin scripts prompts templates VERSION "${INSTALL_DIR}/"
chmod +x "${INSTALL_DIR}/bin/ralph" "${INSTALL_DIR}/scripts/"*.sh

mkdir -p "${LINK_DIR}"
ln -sf "${INSTALL_DIR}/bin/ralph" "${LINK_DIR}/ralph"
echo "Linked: ${LINK_DIR}/ralph → ${INSTALL_DIR}/bin/ralph"

if ! echo ":${PATH}:" | grep -q ":${LINK_DIR}:"; then
  echo ""
  echo "Add to your shell profile (~/.zprofile or ~/.bashrc):"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

echo "Done. Run 'ralph help' to get started."
